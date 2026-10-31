import Foundation

protocol RepoScanner: Sendable {
  func discoverWorktrees(repo: String) async -> [Worktree]
  func discoverBranches(repo: String, worktrees: [Worktree]) async -> [LocalBranch]
  func discoverStashes(repo: String) async -> [Stash]
  func makeAuditor(repo: String) async -> any RepoAuditor
  func diskUsageKB(of path: String) async -> Int?
}

protocol RepoAuditor: Sendable {
  var warnings: [String] { get }
  func audit(_ worktree: Worktree) async -> Worktree
  func audit(_ branch: LocalBranch) async -> LocalBranch
  func audit(_ stash: Stash) async -> Stash
  func preview(_ stash: Stash) async -> StashPreview
  func remove(_ worktree: Worktree, force: Bool) async -> ShellResult
  func delete(_ branch: LocalBranch, force: Bool) async -> ShellResult
  func drop(_ stash: Stash) async -> ShellResult
  func refreshingStashes() async -> any RepoAuditor
}

struct GitScanner: RepoScanner {
  func discoverWorktrees(repo: String) async -> [Worktree] {
    var worktrees = Self.parseWorktrees(await Shell.git(["worktree", "list", "--porcelain"], in: repo).stdout)
    let dates = Self.parseCommitDates(await Shell.git(["log", "--no-walk=unsorted", "--format=%H %ct"] + worktrees.map(\.head), in: repo).lines)
    for i in worktrees.indices {
      worktrees[i].createdAt = (try? FileManager.default.attributesOfItem(atPath: worktrees[i].path))?[.creationDate] as? Date
      worktrees[i].status.lastCommitDate = dates[worktrees[i].head] ?? .distantPast
    }
    return worktrees
  }

  func discoverBranches(repo: String, worktrees: [Worktree]) async -> [LocalBranch] {
    let format = "%(refname:short)|%(objectname)|%(upstream:track)|%(committerdate:unix)"
    return Self.parseBranches(await Shell.git(["for-each-ref", "refs/heads", "--format=\(format)"], in: repo).lines, worktrees: worktrees)
  }

  func discoverStashes(repo: String) async -> [Stash] {
    Self.parseStashes(await Shell.git(["stash", "list", "--format=%H|%ct|%gs"], in: repo).lines)
  }

  func makeAuditor(repo: String) async -> any RepoAuditor {
    await GitAuditor(repo: repo)
  }

  func diskUsageKB(of path: String) async -> Int? {
    Int(await Shell.run("du", ["-sk", path]).stdout.split(separator: "\t").first ?? "")
  }
}
