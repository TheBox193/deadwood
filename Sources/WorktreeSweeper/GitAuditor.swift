import Foundation

/// Serialises `git fetch` calls so parallel audits do not fight over the repo's lock files.
actor FetchGate {
  private var last: Task<Void, Never>?

  func fetchPullRequestHead(_ number: Int, in repo: String) async {
    let previous = last
    let task = Task {
      await previous?.value
      _ = await Shell.git(["fetch", "-q", "--no-tags", "origin", "+refs/pull/\(number)/head:refs/sweeper/pull/\(number)"], in: repo)
    }
    last = task
    await task.value
  }
}

struct GitAuditor: RepoAuditor {
  static let ignoredDirtyPaths: Set<String> = [".vscode/settings.json"]

  let repo: String
  let baseRef: String
  let baseBranch: String
  let warnings: [String]
  private var stashLines: [String]
  private let processCwds: [(command: String, path: String)]
  private let pullRequests: PullRequestCache
  private let fetchGate = FetchGate()
  private let mainIndex: String?

  private static let scratchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-sweeper", isDirectory: true)

  init(repo: String) async {
    self.repo = repo
    var warnings: [String] = []
    let fetch = await Shell.git(["fetch", "-q", "--prune", "origin"], in: repo)
    if !fetch.ok { warnings.append("Could not fetch origin, so merge checks use the last known state: \(fetch.stderr)") }
    let head = await Shell.git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo)
    baseRef = head.ok ? head.stdout : "origin/main"
    baseBranch = String(baseRef.split(separator: "/", maxSplits: 1).last ?? "main")
    stashLines = await Shell.git(["stash", "list", "--format=%gs"], in: repo).lines
    processCwds = GitScanner.parseProcessCwds(await Shell.run("lsof", ["-a", "-d", "cwd", "-u", "\(getuid())", "-Fcn"]).lines)
    try? FileManager.default.createDirectory(at: Self.scratchDirectory, withIntermediateDirectories: true)
    let indexPath = Self.scratchDirectory.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "-") + ".index").path
    let readTree = await Shell.git(["read-tree", baseRef], in: repo, env: ["GIT_INDEX_FILE": indexPath])
    mainIndex = readTree.ok ? indexPath : nil
    if !readTree.ok { warnings.append("Could not index \(baseRef), so stashes are not compared against it: \(readTree.stderr)") }
    pullRequests = await PullRequestCache.load(repo: repo)
    if let failure = pullRequests.failure {
      warnings.append("PR data unavailable, so squash-merged branches look unmerged: \(failure)")
    }
    self.warnings = warnings
  }

  func refreshingStashes() async -> any RepoAuditor {
    var copy = self
    copy.stashLines = await Shell.git(["stash", "list", "--format=%gs"], in: repo).lines
    return copy
  }

  func audit(_ wt: Worktree) async -> Worktree {
    var w = wt
    w.exists = FileManager.default.fileExists(atPath: w.path + "/.git")
    w.status = await branchStatus(head: w.head, branch: w.branch, lastCommitDate: w.status.lastCommitDate)
    if w.branch == nil { w.status.localLabel = w.branchLabel }
    if w.exists {
      w.dirtyFiles = await Shell.git(["status", "--porcelain"], in: w.path).lines
        .map { String($0.dropFirst(3)) }
        .filter { !Self.ignoredDirtyPaths.contains($0) }
    }
    w.usedBy = processesWorking(in: w.path)

    w.notes = []
    if !w.usedBy.isEmpty { w.notes.append("in use by " + w.usedBy.prefix(3).joined(separator: ", ")) }
    if !w.dirtyFiles.isEmpty { w.notes.append("\(w.dirtyFiles.count) uncommitted") }
    w.notes += statusNotes(w.status)

    w.verdict = Judge.worktree(isMainCheckout: w.isMainCheckout, exists: w.exists, markedPrunable: w.markedPrunable,
                               inUse: !w.usedBy.isEmpty, createdAt: w.createdAt, dirty: !w.dirtyFiles.isEmpty, status: w.status)
    w.audited = true
    return w
  }

  func audit(_ branch: LocalBranch) async -> LocalBranch {
    var b = branch
    b.status = await branchStatus(head: b.head, branch: b.name, lastCommitDate: b.status.lastCommitDate)
    b.status.remoteGone = b.upstreamGone

    b.notes = []
    if let path = b.worktreePath { b.notes.append("checked out at \((path as NSString).lastPathComponent)") }
    b.notes += statusNotes(b.status)

    b.verdict = Judge.branch(isBaseBranch: b.name == baseBranch, checkedOut: b.worktreePath != nil, status: b.status)
    b.audited = true
    return b
  }

  func audit(_ stash: Stash) async -> Stash {
    var s = stash
    if let branch = s.branch {
      s.branchExists = await Shell.git(["rev-parse", "--verify", "-q", "refs/heads/\(branch)"], in: repo).ok
    }
    let files = GitScanner.parseNumstat(await Shell.git(["diff", "--no-renames", "--numstat", "\(s.sha)^1", s.sha], in: repo).lines)
    s.fileCount = files.count
    s.fates = await patchFates(of: s.sha, paths: files.map(\.path))

    s.notes = []
    if s.branch != nil && !s.branchExists { s.notes.append("branch deleted") }
    if s.isLintStagedBackup { s.notes.append("lint-staged backup") }
    s.notes.append("\(s.fileCount) file\(s.fileCount == 1 ? "" : "s")")

    s.verdict = Judge.stash(isLintStagedBackup: s.isLintStagedBackup, branchDeleted: s.branch != nil && !s.branchExists,
                            inMain: s.fit.allInMain, date: s.date)
    s.audited = true
    return s
  }

  func preview(_ stash: Stash) async -> StashPreview {
    async let numstat = Shell.git(["diff", "--no-renames", "--numstat", "\(stash.sha)^1", stash.sha], in: repo)
    async let diff = Shell.git(["diff", "--no-renames", "\(stash.sha)^1", stash.sha], in: repo)
    return StashPreview(sha: stash.sha, files: GitScanner.parseNumstat(await numstat.lines), diff: await diff.stdout)
  }

  /// Every check runs against a private index of the base branch (`GIT_INDEX_FILE`) with `--check`, so nothing in the repo is written.
  private func patchFates(of sha: String, paths: [String]) async -> [String: PatchFate] {
    guard let mainIndex, !paths.isEmpty else { return [:] }
    let patch = Self.scratchDirectory.appendingPathComponent("\(sha).patch")
    let diff = await Shell.git(["diff", "--no-renames", "\(sha)^1", sha], in: repo).stdout
    guard (try? (diff + "\n").write(to: patch, atomically: true, encoding: .utf8)) != nil else { return [:] }
    defer { try? FileManager.default.removeItem(at: patch) }
    func passes(_ options: [String]) async -> Bool {
      await Shell.git(["apply", "--check", "--cached"] + options + [patch.path], in: repo, env: ["GIT_INDEX_FILE": mainIndex]).ok
    }
    if await passes(["-R"]) { return Dictionary(uniqueKeysWithValues: paths.map { ($0, PatchFate.inMain) }) }
    if await passes([]) { return Dictionary(uniqueKeysWithValues: paths.map { ($0, PatchFate.applies) }) }
    var fates: [String: PatchFate] = [:]
    for path in paths {
      if await passes(["-R", "--include=\(path)"]) { fates[path] = .inMain }
      else if await passes(["--include=\(path)"]) { fates[path] = .applies }
      else { fates[path] = .conflicts }
    }
    return fates
  }

  private func branchStatus(head: String, branch: String?, lastCommitDate: Date) async -> BranchStatus {
    var s = BranchStatus()
    s.head = head
    s.lastCommitDate = lastCommitDate
    s.ahead = Int(await Shell.git(["rev-list", "--count", "\(baseRef)..\(head)"], in: repo).stdout) ?? 0
    s.inBaseBranch = await Shell.git(["merge-base", "--is-ancestor", head, baseRef], in: repo).ok
    guard let branch else {
      s.remoteName = await Shell.git(["branch", "-r", "--contains", head, "--format=%(refname:short)"], in: repo).lines.first
      s.pullRequest = await pullRequests.lookup(sha: head)
      return s
    }
    s.localLabel = branch
    if await Shell.git(["rev-parse", "--verify", "-q", "origin/\(branch)"], in: repo).ok { s.remoteName = "origin/\(branch)" }
    s.stashes = stashLines.filter { GitScanner.stashBranch($0) == branch }
    s.pullRequest = await pullRequests.lookup(branch: branch)
    if s.pullRequest == nil { s.pullRequest = await pullRequests.lookup(sha: head) }
    if let pr = s.pullRequest, pr.isMerged, pr.headSha != head {
      s.tipWithinMergedPR = await tipIsWithin(prHead: pr.headSha, prNumber: pr.number, tip: head)
    }
    return s
  }

  private func tipIsWithin(prHead: String, prNumber: Int, tip: String) async -> Bool {
    if await !Shell.git(["cat-file", "-e", prHead], in: repo).ok {
      await fetchGate.fetchPullRequestHead(prNumber, in: repo)
    }
    return await Shell.git(["merge-base", "--is-ancestor", tip, prHead], in: repo).ok
  }

  private func processesWorking(in path: String) -> [String] {
    let commands = Set(processCwds.filter { $0.path == path || $0.path.hasPrefix(path + "/") }.map(\.command))
    return commands.sorted { a, b in
      if (a == "claude") != (b == "claude") { return a == "claude" }
      return a.lowercased() < b.lowercased()
    }
  }

  private func statusNotes(_ s: BranchStatus) -> [String] {
    var notes: [String] = []
    if !s.stashes.isEmpty { notes.append("\(s.stashes.count) stash") }
    if s.pullRequest?.isMerged == true && !s.fullyMerged { notes.append("commits beyond merged PR") }
    else if s.ahead > 0 && !s.fullyMerged { notes.append("\(s.ahead) ahead of \(baseRef)") }
    if s.remoteGone { notes.append("remote deleted") }
    else if s.remoteName == nil && !s.fullyMerged { notes.append("not pushed") }
    return notes
  }

  // MARK: Actions

  func remove(_ w: Worktree, force: Bool) async -> ShellResult {
    var result = w.exists
      ? await Shell.git(["worktree", "remove"] + (force ? ["--force"] : []) + [w.path], in: repo)
      : await Shell.git(["worktree", "prune"], in: repo)
    if result.ok, let branch = w.branch { result = await deleteBranch(branch, force: force, status: w.status) }
    return result
  }

  func delete(_ b: LocalBranch, force: Bool) async -> ShellResult {
    await deleteBranch(b.name, force: force, status: b.status)
  }

  /// `git branch -d` only recognises merges it can see in history, so a squash-merged branch needs `-D`.
  private func deleteBranch(_ name: String, force: Bool, status: BranchStatus) async -> ShellResult {
    await Shell.git(["branch", force || !status.inBaseBranch ? "-D" : "-d", name], in: repo)
  }

  func drop(_ stash: Stash) async -> ShellResult {
    let ref = await Shell.git(["stash", "list", "--format=%gd %H"], in: repo).lines
      .first { $0.hasSuffix(stash.sha) }?.split(separator: " ").first
    guard let ref else { return ShellResult(status: 1, stdout: "", stderr: "Stash \(stash.sha.prefix(7)) is no longer in the list") }
    return await Shell.git(["stash", "drop", String(ref)], in: repo)
  }
}
