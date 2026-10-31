import AppKit
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
    if self == .distantPast { return "" }
    let sameYear = Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
    return formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
  }

  var daysAgo: Int { Calendar.current.dateComponents([.day], from: self, to: Date()).day ?? 0 }
}

struct PullRequest: Decodable, Sendable {
  let number: Int
  let state: String
  let branch: String
  let headSha: String
  let url: String
  let mergedAt: Date?
  var isMerged: Bool { state == "MERGED" }
  var isOpen: Bool { state == "OPEN" }

  var icon: String {
    switch state {
    case "MERGED": "arrow.triangle.merge"
    case "OPEN": "arrow.triangle.pull"
    default: "xmark.circle"
    }
  }

  enum CodingKeys: String, CodingKey {
    case number, state, url, mergedAt
    case branch = "headRefName"
    case headSha = "headRefOid"
  }
}

struct BranchStatus: Sendable {
  var head = ""
  var lastCommitDate = Date.distantPast
  var ahead = 0
  var inBaseBranch = false
  var remoteName: String?
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
    return remoteName ?? "not pushed"
  }
}

func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

struct Worktree: Identifiable, Sendable {
  let path: String
  let head: String
  let branch: String?
  let isMainCheckout: Bool
  let markedPrunable: Bool

  var exists = true
  var createdAt: Date?
  var dirtyFiles: [String] = []
  var usedBy: [String] = []
  var diskKB: Int?
  var status = BranchStatus()
  var verdict: Verdict = .active
  var notes: [String] = []
  var audited = false

  var id: String { path }
  var name: String { (path as NSString).lastPathComponent }
  var branchLabel: String { branch ?? "detached @ \(head.prefix(7))" }
  var created: Date { createdAt ?? .distantPast }
  var diskSortKey: Int { diskKB ?? -1 }
  var diskDisplay: String {
    guard let diskKB else { return exists ? "…" : "" }
    return ByteCountFormatter.string(fromByteCount: Int64(diskKB) * 1024, countStyle: .file)
  }
}

struct LocalBranch: Identifiable, Sendable {
  let name: String
  let head: String
  let upstreamGone: Bool

  var worktreePath: String?
  var status = BranchStatus()
  var verdict: Verdict = .active
  var notes: [String] = []
  var audited = false

  var id: String { name }
}

struct Stash: Identifiable, Sendable {
  let sha: String
  let date: Date
  let message: String
  let branch: String?

  var branchExists = false
  var fileCount = 0
  var verdict: Verdict = .active
  var notes: [String] = []
  var audited = false

  var id: String { sha }
  var isLintStagedBackup: Bool { message.hasPrefix("lint-staged automatic backup") }
}

struct StashPreview: Sendable, Equatable {
  struct File: Sendable, Equatable, Identifiable {
    let path: String
    let added: Int?
    let removed: Int?
    var id: String { path }
    var isBinary: Bool { added == nil }
  }

  let sha: String
  let files: [File]
  let diff: String
}

struct OpenTarget: Identifiable {
  let name: String
  let open: (String) -> Void
  var id: String { name }

  static let finder = OpenTarget(name: "Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) }

  static func app(_ name: String) -> OpenTarget? {
    let installed = ["/Applications", NSHomeDirectory() + "/Applications"].contains { FileManager.default.fileExists(atPath: "\($0)/\(name).app") }
    guard installed else { return nil }
    return OpenTarget(name: name) { path in Task { _ = await Shell.run("open", ["-a", name, path]) } }
  }

  static func detectAll() -> [OpenTarget] {
    let apps = ["Terminal", "iTerm", "Warp", "Ghostty", "Visual Studio Code", "Cursor", "Zed", "Sourcetree", "Fork", "Tower", "GitHub Desktop"]
    return [finder] + apps.compactMap(app)
  }
}
