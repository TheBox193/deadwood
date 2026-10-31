import Foundation

actor PullRequestCache {
  private var byBranch: [String: [PullRequest]]
  private var inFlight: [String: Task<[PullRequest], Never>] = [:]
  private let repo: String
  let failure: String?

  static func load(repo: String) async -> PullRequestCache {
    let bulk = await fetch(["--limit", "1000"], repo: repo)
    return PullRequestCache(repo: repo, prs: bulk.prs, failure: bulk.ok ? nil : bulk.stderr)
  }

  private init(repo: String, prs: [PullRequest], failure: String?) {
    self.repo = repo
    self.failure = failure
    byBranch = Dictionary(grouping: prs, by: \.branch)
  }

  func lookup(branch: String) async -> PullRequest? {
    if let cached = byBranch[branch] { return Self.pick(cached) }
    let task = inFlight[branch] ?? Task { [repo] in await Self.fetch(["--head", branch, "--limit", "10"], repo: repo).prs }
    inFlight[branch] = task
    let prs = await task.value
    byBranch[branch] = prs
    inFlight[branch] = nil
    return Self.pick(prs)
  }

  private static func pick(_ prs: [PullRequest]) -> PullRequest? {
    prs.first(where: \.isMerged) ?? prs.first(where: \.isOpen) ?? prs.first
  }

  private static func fetch(_ args: [String], repo: String) async -> (ok: Bool, prs: [PullRequest], stderr: String) {
    let fields = "number,state,headRefName,headRefOid,url,mergedAt"
    let result = await Shell.run("gh", ["pr", "list", "--state", "all", "--json", fields] + args, cwd: repo)
    guard result.ok else { return (false, [], result.stderr) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (true, (try? decoder.decode([PullRequest].self, from: Data(result.stdout.utf8))) ?? [], "")
  }
}

/// Serialises `git fetch` calls so parallel audits do not fight over the repo's lock files.
actor FetchGate {
  private var last: Task<Void, Never>?

  func fetch(_ args: [String], in repo: String) async {
    let previous = last
    let task = Task {
      await previous?.value
      _ = await Shell.git(["fetch", "-q", "origin"] + args, in: repo)
    }
    last = task
    await task.value
  }
}

struct Auditor: Sendable {
  static let ignoredDirtyPaths: Set<String> = [".vscode/settings.json"]

  let repo: String
  let baseRef: String
  let baseBranch: String
  let warnings: [String]
  private var stashLines: [String]
  private let processCwds: [(command: String, path: String)]
  private let pullRequests: PullRequestCache
  private let fetchGate = FetchGate()

  init(repo: String) async {
    self.repo = repo
    var warnings: [String] = []
    let fetch = await Shell.git(["fetch", "-q", "--prune", "origin"], in: repo)
    if !fetch.ok { warnings.append("Could not fetch origin, so merge checks use the last known state: \(fetch.stderr)") }
    let head = await Shell.git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo)
    baseRef = head.ok ? head.stdout : "origin/main"
    baseBranch = String(baseRef.split(separator: "/", maxSplits: 1).last ?? "main")
    stashLines = await Shell.git(["stash", "list", "--format=%gs"], in: repo).lines
    processCwds = Self.parseProcessCwds(await Shell.run("lsof", ["-a", "-d", "cwd", "-u", "\(getuid())", "-Fcn"]).lines)
    pullRequests = await PullRequestCache.load(repo: repo)
    if let failure = pullRequests.failure {
      warnings.append("PR data unavailable, so squash-merged branches look unmerged: \(failure)")
    }
    self.warnings = warnings
  }

  func refreshingStashes() async -> Auditor {
    var copy = self
    copy.stashLines = await Shell.git(["stash", "list", "--format=%gs"], in: repo).lines
    return copy
  }

  static func auditAll<T: Sendable>(_ items: [T], _ audit: @escaping @Sendable (T) async -> T) async -> [T] {
    await withTaskGroup(of: T.self) { group in
      for item in items { group.addTask { await audit(item) } }
      var out: [T] = []
      for await item in group { out.append(item) }
      return out
    }
  }

  // MARK: Discovery

  static func discoverWorktrees(repo: String) async -> [Worktree] {
    var worktrees = parseWorktrees(await Shell.git(["worktree", "list", "--porcelain"], in: repo).stdout)
    let dates = parseCommitDates(await Shell.git(["log", "--no-walk=unsorted", "--format=%H %ct"] + worktrees.map(\.head), in: repo).lines)
    for i in worktrees.indices {
      worktrees[i].createdAt = (try? FileManager.default.attributesOfItem(atPath: worktrees[i].path))?[.creationDate] as? Date
      worktrees[i].status.lastCommitDate = dates[worktrees[i].head] ?? .distantPast
    }
    return worktrees
  }

  static func discoverBranches(repo: String, worktrees: [Worktree]) async -> [LocalBranch] {
    let format = "%(refname:short)|%(objectname)|%(upstream:track)|%(committerdate:unix)"
    return parseBranches(await Shell.git(["for-each-ref", "refs/heads", "--format=\(format)"], in: repo).lines, worktrees: worktrees)
  }

  static func parseCommitDates(_ lines: [String]) -> [String: Date] {
    Dictionary(uniqueKeysWithValues: lines.compactMap { line in
      let parts = line.split(separator: " ")
      guard parts.count == 2, let date = Date(unixSeconds: String(parts[1])) else { return nil }
      return (String(parts[0]), date)
    })
  }

  static func discoverStashes(repo: String) async -> [Stash] {
    parseStashes(await Shell.git(["stash", "list", "--format=%H|%ct|%gs"], in: repo).lines)
  }

  static func parseWorktrees(_ porcelain: String) -> [Worktree] {
    var result: [Worktree] = []
    var path = "", head = "", branch: String?, prunable = false
    let flush = {
      guard !path.isEmpty else { return }
      result.append(Worktree(path: path, head: head, branch: branch, isMainCheckout: result.isEmpty, markedPrunable: prunable))
      path = ""; head = ""; branch = nil; prunable = false
    }
    for line in porcelain.components(separatedBy: "\n") {
      if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst(9)) }
      else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
      else if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst(18)) }
      else if line.hasPrefix("prunable") { prunable = true }
    }
    flush()
    return result
  }

  static func parseBranches(_ lines: [String], worktrees: [Worktree]) -> [LocalBranch] {
    let checkedOut = Dictionary(worktrees.compactMap { w in w.branch.map { ($0, w.path) } }, uniquingKeysWith: { a, _ in a })
    return lines.compactMap { line in
      let parts = line.components(separatedBy: "|")
      guard parts.count == 4 else { return nil }
      var b = LocalBranch(name: parts[0], head: parts[1], upstreamGone: parts[2] == "[gone]")
      b.worktreePath = checkedOut[parts[0]]
      b.status.lastCommitDate = Date(unixSeconds: parts[3]) ?? .distantPast
      return b
    }
  }

  static func parseStashes(_ lines: [String]) -> [Stash] {
    lines.compactMap { line in
      let parts = line.components(separatedBy: "|")
      guard parts.count >= 3, let date = Date(unixSeconds: parts[1]) else { return nil }
      let message = parts[2...].joined(separator: "|")
      return Stash(sha: parts[0], date: date, message: message, branch: stashBranch(message))
    }
  }

  static func stashBranch(_ message: String) -> String? {
    for prefix in ["WIP on ", "On "] where message.hasPrefix(prefix) {
      let rest = message.dropFirst(prefix.count)
      if let colon = rest.firstIndex(of: ":") { return String(rest[..<colon]) }
    }
    return nil
  }

  static func parseProcessCwds(_ lsofLines: [String]) -> [(command: String, path: String)] {
    var result: [(String, String)] = []
    var command = ""
    for line in lsofLines {
      if line.hasPrefix("c") { command = String(line.dropFirst()) }
      else if line.hasPrefix("n") { result.append((command, String(line.dropFirst()))) }
    }
    return result
  }

  // MARK: Auditing

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
    s.fileCount = await Shell.git(["diff", "--name-only", "\(s.sha)^1", s.sha], in: repo).lines.count

    s.notes = []
    if s.branch != nil && !s.branchExists { s.notes.append("branch deleted") }
    if s.isLintStagedBackup { s.notes.append("lint-staged backup") }
    s.notes.append("\(s.fileCount) file\(s.fileCount == 1 ? "" : "s")")

    s.verdict = Judge.stash(isLintStagedBackup: s.isLintStagedBackup, branchDeleted: s.branch != nil && !s.branchExists, date: s.date)
    s.audited = true
    return s
  }

  private func branchStatus(head: String, branch: String?, lastCommitDate: Date) async -> BranchStatus {
    var s = BranchStatus()
    s.head = head
    s.lastCommitDate = lastCommitDate
    s.ahead = Int(await Shell.git(["rev-list", "--count", "\(baseRef)..\(head)"], in: repo).stdout) ?? 0
    s.inBaseBranch = await Shell.git(["merge-base", "--is-ancestor", head, baseRef], in: repo).ok
    guard let branch else { return s }
    s.localLabel = branch
    s.hasRemoteBranch = await Shell.git(["rev-parse", "--verify", "-q", "origin/\(branch)"], in: repo).ok
    s.stashes = stashLines.filter { Self.stashBranch($0) == branch }
    s.pullRequest = await pullRequests.lookup(branch: branch)
    if let pr = s.pullRequest, pr.isMerged, pr.headSha != head {
      s.tipWithinMergedPR = await tipIsWithin(prHead: pr.headSha, prNumber: pr.number, tip: head)
    }
    return s
  }

  private func tipIsWithin(prHead: String, prNumber: Int, tip: String) async -> Bool {
    if await !Shell.git(["cat-file", "-e", prHead], in: repo).ok {
      await fetchGate.fetch(["refs/pull/\(prNumber)/head"], in: repo)
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
    else if !s.localLabel.isEmpty && !s.hasRemoteBranch && !s.fullyMerged { notes.append("not pushed") }
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
