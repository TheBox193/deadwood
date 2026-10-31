import Foundation
import Testing
@testable import WorktreeSweeper

actor Gate {
  private var isOpen: Bool
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(open: Bool) { isOpen = open }

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    waiters.forEach { $0.resume() }
    waiters = []
  }
}

actor FakeAuditor: RepoAuditor {
  let warnings: [String] = ["fake warning"]
  let gate: Gate
  var audited: [String] = []
  var actions: [String] = []
  var actionResult = ShellResult(status: 0, stdout: "", stderr: "")

  init(gateOpen: Bool = true) { gate = Gate(open: gateOpen) }

  func failActions(with stderr: String) { actionResult = ShellResult(status: 1, stdout: "", stderr: stderr) }

  func audit(_ worktree: Worktree) async -> Worktree {
    await gate.wait()
    audited.append(worktree.id)
    var w = worktree
    w.verdict = .dead
    w.audited = true
    return w
  }

  func audit(_ branch: LocalBranch) async -> LocalBranch {
    await gate.wait()
    audited.append(branch.id)
    var b = branch
    b.verdict = .dead
    b.audited = true
    return b
  }

  func audit(_ stash: Stash) async -> Stash {
    await gate.wait()
    audited.append(stash.id)
    var s = stash
    s.audited = true
    return s
  }

  func preview(_ stash: Stash) async -> StashPreview {
    await gate.wait()
    return StashPreview(sha: stash.sha, files: [StashPreview.File(path: "a.swift", added: 1, removed: 2)], diff: "+x\n-y")
  }

  func remove(_ worktree: Worktree, force: Bool) async -> ShellResult { actions.append("remove \(worktree.name) force=\(force)"); return actionResult }
  func delete(_ branch: LocalBranch, force: Bool) async -> ShellResult { actions.append("delete \(branch.name) force=\(force)"); return actionResult }
  func drop(_ stash: Stash) async -> ShellResult { actions.append("drop \(stash.sha)"); return actionResult }
  func refreshingStashes() async -> any RepoAuditor { self }
}

struct FakeScanner: RepoScanner {
  let auditor: FakeAuditor
  let worktrees = [
    Worktree(path: "/repo", head: "aaa", branch: "main", isMainCheckout: true, markedPrunable: false),
    Worktree(path: "/repo/.claude/worktrees/feature", head: "bbb", branch: "feature", isMainCheckout: false, markedPrunable: false),
  ]
  let branches = [
    LocalBranch(name: "main", head: "aaa", upstreamGone: false),
    LocalBranch(name: "feature", head: "bbb", upstreamGone: false),
    LocalBranch(name: "old", head: "ccc", upstreamGone: true),
  ]
  let stashes = [Stash(sha: "ddd", date: Date(), message: "WIP on old: x", branch: "old")]
  let diskKB = ["/repo": 7, "/repo/.claude/worktrees/feature": 42]

  func discoverWorktrees(repo: String) async -> [Worktree] { worktrees }
  func discoverBranches(repo: String, worktrees: [Worktree]) async -> [LocalBranch] { branches }
  func discoverStashes(repo: String) async -> [Stash] { stashes }
  func makeAuditor(repo: String) async -> any RepoAuditor { auditor }
  func diskUsageKB(of path: String) async -> Int? { diskKB[path] }
}

final class Clock {
  var now = Date()
}

private extension Array {
  func allAudited(_ audited: (Element) -> Bool) -> Bool { !isEmpty && allSatisfy(audited) }
}

@MainActor
private func makeModel(_ auditor: FakeAuditor, path: String = "/repo", defaults: UserDefaults = freshDefaults(), clock: Clock = Clock()) -> SweeperModel {
  let model = SweeperModel(scanner: FakeScanner(auditor: auditor), defaults: defaults, openTargets: []) { clock.now }
  model.repoPath = path
  return model
}

private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "WorktreeSweeperTests-\(UUID().uuidString)")! }

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
  for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
  #expect(condition(), sourceLocation: sourceLocation)
}

@MainActor @Test func rescanAuditsOnlyTheVisibleTab() async {
  let auditor = FakeAuditor()
  let model = makeModel(auditor)
  model.rescan()
  await waitUntil { model.worktrees.allAudited(\.audited) && !model.isLoading }
  #expect(await auditor.audited.sorted() == ["/repo", "/repo/.claude/worktrees/feature"])
  #expect(model.branches.allSatisfy { !$0.audited })
  #expect(model.warnings == ["fake warning"])
  #expect(model.worktrees.map(\.diskKB) == [7, 42])

  model.tab = .branches
  await waitUntil { model.branches.allAudited(\.audited) }
  #expect(model.stashes.allSatisfy { !$0.audited })
}

@MainActor @Test func diskSizesLandingMidAuditSurviveTheAudit() async {
  let auditor = FakeAuditor(gateOpen: false)
  let model = makeModel(auditor)
  model.rescan()
  await waitUntil { model.worktrees.compactMap(\.diskKB) == [7, 42] }
  #expect(model.worktrees.allSatisfy { !$0.audited })

  await auditor.gate.open()
  await waitUntil { model.worktrees.allAudited(\.audited) }
  #expect(model.worktrees.map(\.diskKB) == [7, 42])
}

@MainActor @Test func aRowRemovedMidAuditStaysGone() async {
  let auditor = FakeAuditor(gateOpen: false)
  let model = makeModel(auditor)
  model.rescan()
  await waitUntil { model.scannedAt != nil }
  let feature = model.worktrees.first { $0.branch == "feature" }!

  model.remove(feature)
  #expect(model.pending?.message == "This worktree is not marked safe.")
  model.pending?.perform()
  await waitUntil { !model.worktrees.contains { $0.id == feature.id } }
  #expect(model.recovery == Recovery(message: "Removed feature and deleted feature (was bbb)", command: "git branch 'feature' bbb"))
  #expect(!model.branches.contains { $0.name == "feature" })
  #expect(await auditor.actions == ["remove feature force=true"])

  await auditor.gate.open()
  await waitUntil { model.worktrees.allAudited(\.audited) }
  #expect(model.worktrees.map(\.branch) == ["main"])
}

@MainActor @Test func aSafeRowIsRemovedWithoutConfirmation() async {
  let auditor = FakeAuditor()
  let model = makeModel(auditor)
  model.rescan()
  await waitUntil { model.worktrees.allAudited(\.audited) }

  model.remove(model.worktrees.first { $0.branch == "feature" }!)
  #expect(model.pending == nil)
  await waitUntil { model.worktrees.count == 1 }
  #expect(await auditor.actions == ["remove feature force=false"])
  #expect(model.errorMessage == nil)
}

@MainActor @Test func aFailedActionKeepsItsErrorThroughTheReload() async {
  let auditor = FakeAuditor()
  await auditor.failActions(with: "fatal: nope")
  let model = makeModel(auditor)
  model.rescan()
  await waitUntil { model.worktrees.allAudited(\.audited) }

  model.remove(model.worktrees.first { $0.branch == "feature" }!)
  await waitUntil { model.errorMessage == "fatal: nope" }
  await waitUntil { model.worktrees.allAudited(\.audited) && !model.isLoading }
  #expect(model.errorMessage == "fatal: nope")
  #expect(model.worktrees.count == 2)

  model.rescan()
  #expect(model.errorMessage == nil)
}

@MainActor @Test func aStaleScanAsksForARescanInsteadOfDeleting() async {
  let auditor = FakeAuditor()
  let clock = Clock()
  let model = makeModel(auditor, clock: clock)
  model.rescan()
  await waitUntil { model.worktrees.allAudited(\.audited) }

  clock.now += SweeperModel.maxScanAge + 1
  model.remove(model.worktrees.first { $0.branch == "feature" }!)
  #expect(model.rescanNeeded)
  #expect(model.pending == nil)
  #expect(await auditor.actions.isEmpty)
}

@MainActor @Test func theDeleteKeyActsOnTheSelectedRow() async {
  let auditor = FakeAuditor()
  let model = makeModel(auditor)
  model.rescan()
  await waitUntil { model.scannedAt != nil }
  model.tab = .branches
  await waitUntil { model.branches.allAudited(\.audited) }

  model.branchSelection = "old"
  model.removeSelected()
  await waitUntil { !model.branches.contains { $0.name == "old" } }
  #expect(await auditor.actions == ["delete old force=false"])
  #expect(model.recovery?.command == "git branch 'old' ccc")
}

@MainActor @Test func theRepoPathIsRemembered() {
  let defaults = freshDefaults()
  let fresh = SweeperModel(scanner: FakeScanner(auditor: FakeAuditor()), defaults: defaults, openTargets: [])
  #expect(fresh.repoPath == "")
  fresh.repoPath = "~/Code/other"
  #expect(SweeperModel(scanner: FakeScanner(auditor: FakeAuditor()), defaults: defaults, openTargets: []).repoPath == "~/Code/other")
}

@MainActor @Test func selectingAStashLoadsItsPreviewAndDroppingClearsIt() async {
  let auditor = FakeAuditor()
  let model = makeModel(auditor)
  model.rescan()
  await waitUntil { model.scannedAt != nil }
  model.tab = .stashes

  model.stashSelection = "ddd"
  await waitUntil { model.stashPreview?.sha == "ddd" }
  #expect(model.stashPreview?.files.map(\.path) == ["a.swift"])

  model.drop(model.selectedStash!)
  model.pending?.perform()
  await waitUntil { model.stashes.isEmpty }
  #expect(model.stashSelection == nil)
  #expect(model.stashPreview == nil)
  #expect(await auditor.actions == ["drop ddd"])
}

@MainActor @Test func anEmptyRepoPathAsksForAFolderInsteadOfScanning() async {
  let auditor = FakeAuditor()
  let model = makeModel(auditor, path: "")
  model.rescan()
  #expect(model.errorMessage == "Choose a repository folder.")
  #expect(!model.isLoading)
  try? await Task.sleep(for: .milliseconds(50))
  #expect(model.worktrees.isEmpty)
}
