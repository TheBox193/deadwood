import Foundation

final class PullRequestCache: @unchecked Sendable {
  private var byBranch: [String: [PullRequest]] = [:]
  private let lock = NSLock()
  private let repo: String

  init(repo: String) {
    self.repo = repo
    for pr in Self.fetch(["--limit", "1000"], repo: repo) { byBranch[pr.branch, default: []].append(pr) }
  }

  func lookup(branch: String) -> PullRequest? {
    lock.lock()
    let cached = byBranch[branch]
    lock.unlock()
    let prs = cached ?? Self.fetch(["--head", branch, "--limit", "10"], repo: repo)
    if cached == nil {
      lock.lock()
      byBranch[branch] = prs
      lock.unlock()
    }
    return prs.first(where: \.isMerged) ?? prs.first(where: \.isOpen) ?? prs.first
  }

  private static func fetch(_ args: [String], repo: String) -> [PullRequest] {
    let fields = "number,state,headRefName,headRefOid,url,mergedAt"
    let result = Shell.run("gh", ["pr", "list", "--state", "all", "--json", fields] + args, cwd: repo)
    guard result.ok else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([PullRequest].self, from: Data(result.stdout.utf8))) ?? []
  }
}

struct Auditor: Sendable {
  static let ignoredDirtyPaths: Set<String> = [".vscode/settings.json"]
  static let staleAfterDays = 14
  static let staleStashAfterDays = 30

  let repo: String
  let baseRef: String
  let baseBranch: String
  private let stashLines: [String]
  private let processCwds: [(command: String, path: String)]
  private let pullRequests: PullRequestCache

  init(repo: String) {
    self.repo = repo
    _ = Shell.git(["fetch", "-q", "--prune", "origin"], in: repo)
    let head = Shell.git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo)
    baseRef = head.ok ? head.stdout : "origin/main"
    baseBranch = String(baseRef.split(separator: "/", maxSplits: 1).last ?? "main")
    stashLines = Shell.git(["stash", "list", "--format=%gs"], in: repo).lines
    processCwds = Self.listProcessCwds()
    pullRequests = PullRequestCache(repo: repo)
  }

  static func auditAll<T: Sendable>(_ items: [T], _ audit: @escaping @Sendable (T) -> T) async -> [T] {
    await withTaskGroup(of: T.self) { group in
      for item in items { group.addTask { audit(item) } }
      var out: [T] = []
      for await item in group { out.append(item) }
      return out
    }
  }

  private static func listProcessCwds() -> [(command: String, path: String)] {
    var result: [(String, String)] = []
    var command = ""
    for line in Shell.run("lsof", ["-a", "-d", "cwd", "-u", "\(getuid())", "-Fcn"]).lines {
      if line.hasPrefix("c") { command = String(line.dropFirst()) }
      else if line.hasPrefix("n") { result.append((command, String(line.dropFirst()))) }
    }
    return result
  }

  // MARK: Discovery

  func discoverWorktrees() -> [Worktree] {
    var result: [Worktree] = []
    var path = "", head = "", branch: String?, prunable = false
    let flush = {
      guard !path.isEmpty else { return }
      result.append(Worktree(path: path, head: head, branch: branch, isMainCheckout: result.isEmpty, markedPrunable: prunable))
      path = ""; head = ""; branch = nil; prunable = false
    }
    for line in Shell.git(["worktree", "list", "--porcelain"], in: repo).stdout.components(separatedBy: "\n") {
      if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst(9)) }
      else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
      else if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst(18)) }
      else if line.hasPrefix("prunable") { prunable = true }
    }
    flush()
    return result
  }

  func discoverBranches(worktrees: [Worktree]) -> [LocalBranch] {
    let checkedOut = Dictionary(worktrees.compactMap { w in w.branch.map { ($0, w.path) } }, uniquingKeysWith: { a, _ in a })
    return Shell.git(["for-each-ref", "refs/heads", "--format=%(refname:short)|%(objectname)|%(upstream:track)"], in: repo).lines.compactMap { line in
      let parts = line.components(separatedBy: "|")
      guard parts.count == 3 else { return nil }
      var b = LocalBranch(name: parts[0], head: parts[1], upstreamGone: parts[2] == "[gone]")
      b.worktreePath = checkedOut[parts[0]]
      return b
    }
  }

  func discoverStashes() -> [Stash] {
    Shell.git(["stash", "list", "--format=%H|%ct|%gs"], in: repo).lines.compactMap { line in
      let parts = line.components(separatedBy: "|")
      guard parts.count >= 3, let date = Date(unixSeconds: parts[1]) else { return nil }
      let message = parts[2...].joined(separator: "|")
      return Stash(sha: parts[0], date: date, message: message, branch: Self.stashBranch(message))
    }
  }

  private static func stashBranch(_ message: String) -> String? {
    for prefix in ["WIP on ", "On "] where message.hasPrefix(prefix) {
      let rest = message.dropFirst(prefix.count)
      if let colon = rest.firstIndex(of: ":") { return String(rest[..<colon]) }
    }
    return nil
  }

  // MARK: Auditing

  func audit(_ wt: Worktree) -> Worktree {
    var w = wt
    w.exists = FileManager.default.fileExists(atPath: w.path + "/.git")
    w.status = branchStatus(head: w.head, branch: w.branch)
    if w.branch == nil { w.status.localLabel = w.branchLabel }
    if w.exists {
      w.dirtyFiles = Shell.git(["status", "--porcelain"], in: w.path).lines
        .map { String($0.dropFirst(3)) }
        .filter { !Self.ignoredDirtyPaths.contains($0) }
    }
    w.usedBy = processesWorking(in: w.path)

    w.notes = []
    if !w.usedBy.isEmpty { w.notes.append("in use by " + w.usedBy.prefix(3).joined(separator: ", ")) }
    if !w.dirtyFiles.isEmpty { w.notes.append("\(w.dirtyFiles.count) uncommitted") }
    w.notes += statusNotes(w.status)

    w.verdict = {
      if w.isMainCheckout { return .main }
      if !w.exists || w.markedPrunable { return .prunable }
      if !w.usedBy.isEmpty { return .inUse }
      if let v = mergedVerdict(w.status, hasLeftovers: !w.dirtyFiles.isEmpty || !w.status.stashes.isEmpty) { return v }
      if w.status.fullyMerged { return w.dirtyFiles.isEmpty ? .nearDead : .active }
      return w.status.lastCommitDate.daysAgo > Self.staleAfterDays ? .stale : .active
    }()
    return w
  }

  func audit(_ branch: LocalBranch) -> LocalBranch {
    var b = branch
    b.status = branchStatus(head: b.head, branch: b.name)
    b.status.remoteGone = b.upstreamGone

    b.notes = []
    if let path = b.worktreePath { b.notes.append("checked out at \((path as NSString).lastPathComponent)") }
    b.notes += statusNotes(b.status)

    b.verdict = {
      if b.name == baseBranch { return .main }
      if b.worktreePath != nil { return .inUse }
      if let v = mergedVerdict(b.status, hasLeftovers: !b.status.stashes.isEmpty) { return v }
      if b.status.fullyMerged { return .nearDead }
      return b.status.lastCommitDate.daysAgo > Self.staleAfterDays ? .stale : .active
    }()
    return b
  }

  func audit(_ stash: Stash) -> Stash {
    var s = stash
    if let branch = s.branch {
      s.branchExists = Shell.git(["rev-parse", "--verify", "-q", "refs/heads/\(branch)"], in: repo).ok
    }
    s.fileCount = Shell.git(["diff", "--name-only", "\(s.sha)^1", s.sha], in: repo).lines.count

    s.notes = []
    if s.branch != nil && !s.branchExists { s.notes.append("branch deleted") }
    if s.isLintStagedBackup { s.notes.append("lint-staged backup") }
    s.notes.append("\(s.fileCount) file\(s.fileCount == 1 ? "" : "s")")

    s.verdict = {
      if s.isLintStagedBackup { return .dead }
      if s.branch != nil && !s.branchExists { return .nearDead }
      return s.date.daysAgo > Self.staleStashAfterDays ? .stale : .active
    }()
    return s
  }

  private func branchStatus(head: String, branch: String?) -> BranchStatus {
    var s = BranchStatus()
    s.head = head
    s.lastCommitDate = Date(unixSeconds: Shell.git(["log", "-1", "--format=%ct", head], in: repo).stdout) ?? .distantPast
    s.ahead = Int(Shell.git(["rev-list", "--count", "\(baseRef)..\(head)"], in: repo).stdout) ?? 0
    s.inBaseBranch = Shell.git(["merge-base", "--is-ancestor", head, baseRef], in: repo).ok
    guard let branch else { return s }
    s.localLabel = branch
    s.hasRemoteBranch = Shell.git(["rev-parse", "--verify", "-q", "origin/\(branch)"], in: repo).ok
    s.stashes = stashLines.filter { Self.stashBranch($0) == branch }
    s.pullRequest = pullRequests.lookup(branch: branch)
    if let pr = s.pullRequest, pr.isMerged, pr.headSha != head {
      s.tipWithinMergedPR = tipIsWithin(prHead: pr.headSha, prNumber: pr.number, tip: head)
    }
    return s
  }

  private func tipIsWithin(prHead: String, prNumber: Int, tip: String) -> Bool {
    if !Shell.git(["cat-file", "-e", prHead], in: repo).ok {
      _ = Shell.git(["fetch", "-q", "origin", "refs/pull/\(prNumber)/head"], in: repo)
    }
    return Shell.git(["merge-base", "--is-ancestor", tip, prHead], in: repo).ok
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
    if s.pullRequest?.isMerged == true && !s.fullyMerged { notes.append("has commits that were not in the merged PR") }
    else if s.ahead > 0 && !s.fullyMerged { notes.append("\(s.ahead) ahead of \(baseRef)") }
    if s.remoteGone { notes.append("remote deleted") }
    else if !s.localLabel.isEmpty && !s.hasRemoteBranch && !s.fullyMerged { notes.append("not pushed") }
    return notes
  }

  private func mergedVerdict(_ s: BranchStatus, hasLeftovers: Bool) -> Verdict? {
    if s.pullRequest?.isOpen == true { return .active }
    if s.fullyMerged && !hasLeftovers { return .dead }
    if s.pullRequest?.isMerged == true { return .nearDead }
    return nil
  }

  // MARK: Actions

  func remove(_ w: Worktree) -> ShellResult {
    var result = w.exists
      ? Shell.git(["worktree", "remove", "--force", w.path], in: repo)
      : Shell.git(["worktree", "prune"], in: repo)
    if result.ok, let branch = w.branch { result = Shell.git(["branch", "-D", branch], in: repo) }
    return result
  }

  func delete(_ b: LocalBranch) -> ShellResult {
    Shell.git(["branch", "-D", b.name], in: repo)
  }

  func drop(_ stash: Stash) -> ShellResult {
    let ref = Shell.git(["stash", "list", "--format=%gd %H"], in: repo).lines
      .first { $0.hasSuffix(stash.sha) }?.split(separator: " ").first
    guard let ref else { return ShellResult(status: 1, stdout: "", stderr: "Stash \(stash.sha.prefix(7)) is no longer in the list") }
    return Shell.git(["stash", "drop", String(ref)], in: repo)
  }
}
