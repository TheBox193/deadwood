import AppKit
import SwiftUI

struct PendingAction: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let buttonLabel: String
  let perform: () -> Void
}

struct Recovery {
  let message: String
  let command: String?
}

@MainActor
final class SweeperModel: ObservableObject {
  static let defaultRepo = ""
  static let maxScanAge: TimeInterval = 20 * 60
  private static let repoPathKey = "repoPath"
  enum Tab: CaseIterable { case worktrees, branches, stashes }

  @Published var repoPath = UserDefaults.standard.string(forKey: repoPathKey) ?? defaultRepo {
    didSet { UserDefaults.standard.set(repoPath, forKey: Self.repoPathKey) }
  }
  @Published var tab: Tab = .worktrees { didSet { load(tab) } }
  @Published var worktrees: [Worktree] = []
  @Published var branches: [LocalBranch] = []
  @Published var stashes: [Stash] = []
  @Published private(set) var activeLoads = 0
  @Published var errorMessage: String?
  @Published var warnings: [String] = []
  @Published var recovery: Recovery?
  @Published var pending: PendingAction?
  @Published var scannedAt: Date?
  @Published var rescanNeeded = false
  @Published var worktreeSelection: Worktree.ID?
  @Published var branchSelection: LocalBranch.ID?
  @Published var stashSelection: Stash.ID?
  @Published var worktreeSort = [KeyPathComparator(\Worktree.verdict), KeyPathComparator(\Worktree.status.lastCommitDate)]
  @Published var branchSort = [KeyPathComparator(\LocalBranch.verdict), KeyPathComparator(\LocalBranch.status.lastCommitDate)]
  @Published var stashSort = [KeyPathComparator(\Stash.verdict), KeyPathComparator(\Stash.date)]
  let openTargets = OpenTarget.detectAll()

  private var auditor: Auditor?
  private var loaded: Set<Tab> = []
  private var tasks: [Task<Void, Never>] = []

  var isLoading: Bool { activeLoads > 0 }

  var totalDiskDisplay: String? {
    let known = worktrees.compactMap(\.diskKB)
    guard !known.isEmpty else { return nil }
    return ByteCountFormatter.string(fromByteCount: Int64(known.reduce(0, +)) * 1024, countStyle: .file)
  }

  // MARK: Loading

  func rescan() {
    tasks.forEach { $0.cancel() }
    tasks = []
    auditor = nil
    loaded = []
    activeLoads = 0
    errorMessage = nil
    warnings = []
    recovery = nil
    let repo = (repoPath as NSString).expandingTildeInPath
    track(Task {
      let foundWorktrees = await Auditor.discoverWorktrees(repo: repo)
      worktrees = foundWorktrees
      if foundWorktrees.isEmpty { errorMessage = "No worktrees found at \(repo). Is it a git repo?" }
      branches = await Auditor.discoverBranches(repo: repo, worktrees: foundWorktrees)
      stashes = await Auditor.discoverStashes(repo: repo)
      let auditor = await Auditor(repo: repo)
      guard !Task.isCancelled else { return }
      self.auditor = auditor
      scannedAt = Date()
      warnings = auditor.warnings
      load(tab)
      await measureDiskUsage(foundWorktrees.filter(\.exists).map(\.path))
    })
  }

  private func load(_ tab: Tab) {
    guard let auditor, !loaded.contains(tab) else { return }
    loaded.insert(tab)
    switch tab {
    case .worktrees:
      track(Task { await fill(worktrees, sortedBy: worktreeSort, audit: { await auditor.audit($0) }) { self.worktrees = $0 } })
    case .branches:
      track(Task { await fill(branches, sortedBy: branchSort, audit: { await auditor.audit($0) }) { self.branches = $0 } })
    case .stashes:
      track(Task { await fill(stashes, sortedBy: stashSort, audit: { await auditor.audit($0) }) { self.stashes = $0 } })
    }
  }

  private func track(_ work: Task<Void, Never>) {
    activeLoads += 1
    tasks.append(work)
    Task {
      await work.value
      if !work.isCancelled { activeLoads -= 1 }
    }
  }

  private func fill<T: Identifiable & Sendable>(_ items: [T], sortedBy sort: [KeyPathComparator<T>],
                                                audit: @escaping @Sendable (T) async -> T, update: ([T]) -> Void) async {
    var rows = items
    await withTaskGroup(of: T.self) { group in
      for item in items { group.addTask { await audit(item) } }
      for await audited in group {
        if Task.isCancelled { group.cancelAll(); return }
        if let index = rows.firstIndex(where: { $0.id == audited.id }) {
          rows[index] = audited
          update(rows)
        }
      }
    }
    guard !Task.isCancelled else { return }
    rows.sort(using: sort)
    update(rows)
  }

  private func measureDiskUsage(_ paths: [String]) async {
    await withTaskGroup(of: (String, Int?).self) { group in
      for path in paths {
        group.addTask { (path, Int(await Shell.run("du", ["-sk", path]).stdout.split(separator: "\t").first ?? "")) }
      }
      for await (path, kb) in group {
        if Task.isCancelled { group.cancelAll(); return }
        if let index = worktrees.firstIndex(where: { $0.path == path }) { worktrees[index].diskKB = kb }
      }
    }
  }

  // MARK: Actions

  func browse() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.directoryURL = URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    repoPath = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    rescan()
  }

  func removeSelected() {
    switch tab {
    case .worktrees: if let w = worktrees.first(where: { $0.id == worktreeSelection }), w.audited, w.verdict.canClean { remove(w) }
    case .branches: if let b = branches.first(where: { $0.id == branchSelection }), b.audited, b.verdict.canClean, b.worktreePath == nil { delete(b) }
    case .stashes: if let s = stashes.first(where: { $0.id == stashSelection }), s.audited { drop(s) }
    }
  }

  private var scanIsFresh: Bool {
    guard let scannedAt else { return false }
    return Date().timeIntervalSince(scannedAt) <= Self.maxScanAge
  }

  private func readyAuditor() -> Auditor? {
    guard scanIsFresh else { rescanNeeded = true; return nil }
    return auditor
  }

  func remove(_ w: Worktree) {
    guard let auditor = readyAuditor() else { return }
    let safe = w.verdict.isSafeToClean
    let perform = {
      self.run({ await auditor.remove(w, force: !safe) }) {
        self.worktrees.removeAll { $0.id == w.id }
        self.branches.removeAll { $0.name == w.branch }
        self.recovery = w.branch.map { Recovery(message: "Removed \(w.name) and deleted \($0) (was \(w.head.prefix(7)))", command: "git branch \($0) \(w.head)") }
          ?? Recovery(message: "Removed \(w.name)", command: nil)
      }
    }
    if safe { return perform() }
    var lines = lossLines(w.status)
    if !w.usedBy.isEmpty { lines.insert("Processes are working in it: " + w.usedBy.joined(separator: ", "), at: 0) }
    if !w.dirtyFiles.isEmpty { lines.insert("Uncommitted: " + w.dirtyFiles.prefix(5).joined(separator: ", ") + (w.dirtyFiles.count > 5 ? ", …" : ""), at: 0) }
    pending = PendingAction(title: "Remove \(w.name)?", message: lines.isEmpty ? "This worktree is not marked safe." : lines.joined(separator: "\n"),
                            buttonLabel: "Remove worktree and branch", perform: perform)
  }

  func delete(_ b: LocalBranch) {
    guard let auditor = readyAuditor() else { return }
    let safe = b.verdict.isSafeToClean
    let perform = {
      self.run({ await auditor.delete(b, force: !safe) }) {
        self.branches.removeAll { $0.id == b.id }
        self.recovery = Recovery(message: "Deleted \(b.name) (was \(b.head.prefix(7)))", command: "git branch \(b.name) \(b.head)")
      }
    }
    if safe { return perform() }
    let lines = lossLines(b.status)
    pending = PendingAction(title: "Delete branch \(b.name)?", message: lines.isEmpty ? "This branch is not marked safe." : lines.joined(separator: "\n"),
                            buttonLabel: "Delete branch", perform: perform)
  }

  func drop(_ s: Stash) {
    guard let auditor = readyAuditor() else { return }
    pending = PendingAction(title: "Drop this stash?",
                            message: "\(s.message)\n\(s.fileCount) file(s) from \(s.date.shortDisplay).",
                            buttonLabel: "Drop stash") {
      self.run({ await auditor.drop(s) }) {
        self.stashes.removeAll { $0.id == s.id }
        self.recovery = Recovery(message: "Dropped stash \(s.sha.prefix(7))", command: "git stash store -m \"\(s.message)\" \(s.sha)")
      }
    }
  }

  private func lossLines(_ s: BranchStatus) -> [String] {
    var lines: [String] = []
    if s.ahead > 0 && !s.fullyMerged { lines.append("\(s.ahead) commit(s) not in main will be lost with the branch.") }
    if s.pullRequest?.isMerged == true && !s.fullyMerged { lines.append("Its PR merged, but this has commits that were not part of it.") }
    return lines
  }

  private func run(_ action: @escaping @Sendable () async -> ShellResult, onSuccess: @escaping () -> Void) {
    activeLoads += 1
    Task {
      let result = await action()
      activeLoads -= 1
      guard result.ok else {
        errorMessage = result.stderr
        return rescan()
      }
      onSuccess()
      if let auditor { self.auditor = await auditor.refreshingStashes() }
      loaded = [tab]
    }
  }
}

func copyToClipboard(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}
