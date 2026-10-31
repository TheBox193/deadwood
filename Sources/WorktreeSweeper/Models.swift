import Foundation

enum Verdict: String, Comparable, CaseIterable {
  case prunable = "Prunable"
  case dead = "Dead"
  case nearDead = "Near-dead"
  case stale = "Stale"
  case inUse = "In use"
  case active = "Active"
  case main = "Main"

  static func < (a: Verdict, b: Verdict) -> Bool {
    allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
  }

  var isSafeToClean: Bool { self == .prunable || self == .dead }
  var canClean: Bool { self != .main }
}

extension Date {
  init?(unixSeconds: String) {
    guard let seconds = TimeInterval(unixSeconds) else { return nil }
    self.init(timeIntervalSince1970: seconds)
  }

  var shortDisplay: String {
    let sameYear = Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
    return formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
  }

  var daysAgo: Int { Calendar.current.dateComponents([.day], from: self, to: Date()).day ?? 0 }
}

struct PullRequest: Decodable {
  let number: Int
  let state: String
  let branch: String
  let headSha: String
  let url: String
  let mergedAt: Date?
  var isMerged: Bool { state == "MERGED" }
  var isOpen: Bool { state == "OPEN" }

  enum CodingKeys: String, CodingKey {
    case number, state, url, mergedAt
    case branch = "headRefName"
    case headSha = "headRefOid"
  }
}

struct BranchStatus {
  var head = ""
  var lastCommitDate = Date.distantPast
  var ahead = 0
  var inBaseBranch = false
  var hasRemoteBranch = false
  var remoteGone = false
  var stashes: [String] = []
  var pullRequest: PullRequest?
  var tipWithinMergedPR = false
  var localLabel = ""

  var fullyMerged: Bool {
    inBaseBranch || (pullRequest?.isMerged == true && (pullRequest?.headSha == head || tipWithinMergedPR))
  }
  var mergedRank: Int { fullyMerged ? 2 : (pullRequest?.isMerged == true ? 1 : 0) }
  var remoteLabel: String {
    if remoteGone { return "remote deleted" }
    return hasRemoteBranch ? "origin/\(localLabel)" : "not pushed"
  }
}

struct Worktree: Identifiable {
  let path: String
  let head: String
  let branch: String?
  let isMainCheckout: Bool
  let markedPrunable: Bool

  var exists = true
  var dirtyFiles: [String] = []
  var usedBy: [String] = []
  var diskKB: Int?
  var status = BranchStatus()
  var verdict: Verdict = .active
  var notes: [String] = []

  var id: String { path }
  var name: String { (path as NSString).lastPathComponent }
  var branchLabel: String { branch ?? "detached @ \(head.prefix(7))" }
  var diskSortKey: Int { diskKB ?? -1 }
  var diskDisplay: String {
    guard let diskKB else { return exists ? "…" : "" }
    return ByteCountFormatter.string(fromByteCount: Int64(diskKB) * 1024, countStyle: .file)
  }
}

struct LocalBranch: Identifiable {
  let name: String
  let head: String
  let upstreamGone: Bool

  var worktreePath: String?
  var status = BranchStatus()
  var verdict: Verdict = .active
  var notes: [String] = []

  var id: String { name }
}

struct Stash: Identifiable {
  let sha: String
  let date: Date
  let message: String
  let branch: String?

  var branchExists = false
  var fileCount = 0
  var verdict: Verdict = .active
  var notes: [String] = []

  var id: String { sha }
  var isLintStagedBackup: Bool { message.hasPrefix("lint-staged automatic backup") }
}
