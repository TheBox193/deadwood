import AppKit
import SwiftUI

struct PendingAction: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let buttonLabel: String
  let perform: () -> Void
}

@MainActor
final class SweeperModel: ObservableObject {
  static let defaultRepo = ""
  enum Tab: CaseIterable { case worktrees, branches, stashes }

  @Published var repoPath = defaultRepo
  @Published var tab: Tab = .worktrees { didSet { if !loaded.contains(tab) { load(tab) } } }
  @Published var worktrees: [Worktree] = []
  @Published var branches: [LocalBranch] = []
  @Published var stashes: [Stash] = []
  @Published var isLoading = false
  @Published var errorMessage: String?
  @Published var pending: PendingAction?
  @Published var scannedAt: Date?
  @Published var rescanNeeded = false
  static let maxScanAge: TimeInterval = 20 * 60
  @Published var worktreeSelection: Worktree.ID?
  @Published var branchSelection: LocalBranch.ID?
  @Published var stashSelection: Stash.ID?
  @Published var worktreeSort = [KeyPathComparator(\Worktree.verdict), KeyPathComparator(\Worktree.status.lastCommitDate)]
  @Published var branchSort = [KeyPathComparator(\LocalBranch.verdict), KeyPathComparator(\LocalBranch.status.lastCommitDate)]
  @Published var stashSort = [KeyPathComparator(\Stash.verdict), KeyPathComparator(\Stash.date)]
  let openTargets = OpenTarget.detectAll()

  private var auditor: Auditor?
  private var loaded: Set<Tab> = []

  var totalDiskDisplay: String? {
    let known = worktrees.compactMap(\.diskKB)
    guard !known.isEmpty else { return nil }
    return ByteCountFormatter.string(fromByteCount: Int64(known.reduce(0, +)) * 1024, countStyle: .file)
  }

  // MARK: Loading

  func rescan() {
    auditor = nil
    loaded = []
    load(tab)
  }

  
  private func load(_ tab: Tab) {
    let repo = (repoPath as NSString).expandingTildeInPath
    let existing = auditor
    isLoading = true
    errorMessage = nil
    Task.detached {
      let foundWorktrees = Auditor.discoverWorktrees(repo: repo)
      await MainActor.run {
        self.worktrees = foundWorktrees
        if foundWorktrees.isEmpty { self.errorMessage = "No worktrees found at \(repo). Is it a git repo?" }
      }
      let foundBranches = Auditor.discoverBranches(repo: repo, worktrees: foundWorktrees)
      let foundStashes = Auditor.discoverStashes(repo: repo)
      await MainActor.run {
        if existing == nil || tab == .branches { self.branches = foundBranches }
        if existing == nil || tab == .stashes { self.stashes = foundStashes }
      }

      let auditor = existing ?? Auditor(repo: repo)
      await MainActor.run {
        self.auditor = auditor
        if existing == nil { self.scannedAt = Date() }
      }
      await self.fill(foundWorktrees, sortedBy: self.worktreeSort, audit: { auditor.audit($0) }) { self.worktrees = $0 }
      await MainActor.run { self.loaded.formUnion([.worktrees]) }
      if tab == .branches {
        await self.fill(foundBranches, sortedBy: self.branchSort, audit: { auditor.audit($0) }) { self.branches = $0 }
        await MainActor.run { self.loaded.formUnion([.branches]) }
      }
      if tab == .stashes {
        await self.fill(foundStashes, sortedBy: self.stashSort, audit: { auditor.audit($0) }) { self.stashes = $0 }
        await MainActor.run { self.loaded.formUnion([.stashes]) }
      }
      await MainActor.run { self.isLoading = false }
      if existing == nil { await self.measureDiskUsage(foundWorktrees.filter(\.exists).map(\.path)) }
    }
  }

  private func fill<T: Identifiable & Sendable>(_ items: [T], sortedBy sort: [KeyPathComparator<T>],
                                                audit: @escaping @Sendable (T) -> T, update: @MainActor ([T]) -> Void) async {
    var rows = items
    await withTaskGroup(of: T.self) { group in
      for item in items { group.addTask { audit(item) } }
      for await audited in group {
        if let index = rows.firstIndex(where: { $0.id == audited.id }) {
          rows[index] = audited
          update(rows)
        }
      }
    }
    rows.sort(using: sort)
    update(rows)
  }

  private func measureDiskUsage(_ paths: [String]) async {
    await withTaskGroup(of: (String, Int?).self) { group in
      for path in paths {
        group.addTask { (path, Int(Shell.run("du", ["-sk", path]).stdout.split(separator: "\t").first ?? "")) }
      }
      for await (path, kb) in group {
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

  private var scanIsFresh: Bool {
    guard let scannedAt, Date().timeIntervalSince(scannedAt) <= Self.maxScanAge else {
      rescanNeeded = true
      return false
    }
    return true
  }

  func remove(_ w: Worktree) {
    guard scanIsFresh, let auditor else { return }
    let perform = { self.run({ auditor.remove(w) }) { self.worktrees.removeAll { $0.id == w.id }; self.branches.removeAll { $0.name == w.branch } } }
    if w.verdict.isSafeToClean { return perform() }
    var lines = lossLines(w.status)
    if !w.usedBy.isEmpty { lines.insert("Processes are working in it: " + w.usedBy.joined(separator: ", "), at: 0) }
    if !w.dirtyFiles.isEmpty { lines.insert("Uncommitted: " + w.dirtyFiles.prefix(5).joined(separator: ", ") + (w.dirtyFiles.count > 5 ? ", …" : ""), at: 0) }
    pending = PendingAction(title: "Remove \(w.name)?", message: lines.isEmpty ? "This worktree is not marked safe." : lines.joined(separator: "\n"),
                            buttonLabel: "Remove worktree and branch", perform: perform)
  }

  func delete(_ b: LocalBranch) {
    guard scanIsFresh, let auditor else { return }
    let perform = { self.run({ auditor.delete(b) }) { self.branches.removeAll { $0.id == b.id } } }
    if b.verdict.isSafeToClean { return perform() }
    let lines = lossLines(b.status)
    pending = PendingAction(title: "Delete branch \(b.name)?", message: lines.isEmpty ? "This branch is not marked safe." : lines.joined(separator: "\n"),
                            buttonLabel: "Delete branch", perform: perform)
  }

  func drop(_ s: Stash) {
    guard scanIsFresh, let auditor else { return }
    pending = PendingAction(title: "Drop this stash?",
                            message: "\(s.message)\n\(s.fileCount) file(s) from \(s.date.shortDisplay). Dropping a stash cannot be undone from the app.",
                            buttonLabel: "Drop stash") {
      self.run({ auditor.drop(s) }) { self.stashes.removeAll { $0.id == s.id } }
    }
  }

  private func lossLines(_ s: BranchStatus) -> [String] {
    var lines: [String] = []
    if s.ahead > 0 && !s.fullyMerged { lines.append("\(s.ahead) commit(s) not in main will be lost with the branch.") }
    if !s.stashes.isEmpty { lines.append("Stashes stay in the repo: " + s.stashes.joined(separator: "; ")) }
    if s.pullRequest?.isMerged == true && !s.fullyMerged { lines.append("Its PR merged, but this has commits that were not part of it.") }
    return lines
  }

  private func run(_ action: @escaping @Sendable () -> ShellResult, onSuccess: @escaping @MainActor () -> Void) {
    isLoading = true
    Task.detached {
      let result = action()
      await MainActor.run {
        if result.ok {
          onSuccess()
          self.isLoading = false
        } else {
          self.errorMessage = result.stderr
          self.rescan()
        }
      }
    }
  }
}

func copyToClipboard(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}
