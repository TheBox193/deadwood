import Foundation
import Testing
@testable import WorktreeSweeper

private let today = Date()
private let lastMonth = Calendar.current.date(byAdding: .day, value: -40, to: today)!

private func pr(_ state: String, head: String = "abc") -> PullRequest {
  PullRequest(number: 1, state: state, branch: "b", headSha: head, url: "https://example.test/1", mergedAt: nil)
}

private func status(head: String = "abc", date: Date = today, inBase: Bool = false, pr: PullRequest? = nil,
                    tipWithinPR: Bool = false, stashes: [String] = []) -> BranchStatus {
  var s = BranchStatus()
  s.head = head
  s.lastCommitDate = date
  s.inBaseBranch = inBase
  s.pullRequest = pr
  s.tipWithinMergedPR = tipWithinPR
  s.stashes = stashes
  return s
}

private func worktree(status s: BranchStatus, exists: Bool = true, prunable: Bool = false, inUse: Bool = false,
                      createdAt: Date? = lastMonth, dirty: Bool = false) -> Verdict {
  Judge.worktree(isMainCheckout: false, exists: exists, markedPrunable: prunable, inUse: inUse, createdAt: createdAt, dirty: dirty, status: s)
}

@Test func mainCheckoutIsAlwaysMain() {
  #expect(Judge.worktree(isMainCheckout: true, exists: true, markedPrunable: false, inUse: true, createdAt: nil, dirty: true, status: status()) == .main)
}

@Test func missingFolderIsPrunableEvenWithUnmergedCommits() {
  #expect(worktree(status: status(date: lastMonth), exists: false) == .prunable)
}

@Test func mergedPRWithMatchingTipIsDead() {
  #expect(worktree(status: status(pr: pr("MERGED"))) == .dead)
}

@Test func mergedPRWithAncestorTipIsDead() {
  #expect(worktree(status: status(head: "older", pr: pr("MERGED", head: "newer"), tipWithinPR: true)) == .dead)
}

@Test func mergedPRWithExtraCommitsIsNearDead() {
  #expect(worktree(status: status(head: "extra", pr: pr("MERGED", head: "merged"))) == .nearDead)
}

@Test func mergedButStrayFilesIsNearDead() {
  #expect(worktree(status: status(pr: pr("MERGED")), dirty: true) == .nearDead)
}

@Test func stashesDoNotKeepAMergedBranchAlive() {
  #expect(worktree(status: status(pr: pr("MERGED"), stashes: ["On b: wip"])) == .dead)
  #expect(Judge.branch(isBaseBranch: false, checkedOut: false, status: status(pr: pr("MERGED"), stashes: ["On b: wip"])) == .dead)
}

@Test func emptyFolderAddedTodayIsActiveUnlessInUseOrMissing() {
  #expect(worktree(status: status(inBase: true), createdAt: today) == .active)
  #expect(worktree(status: status(inBase: true), createdAt: today, dirty: true) == .active)
  #expect(worktree(status: status(inBase: true), inUse: true, createdAt: today) == .inUse)
  #expect(worktree(status: status(inBase: true), exists: false, createdAt: today) == .prunable)
  #expect(worktree(status: status(inBase: true), createdAt: nil) == .dead)
}

@Test func freshFolderOnABranchWithItsOwnCommitsFollowsTheNormalRules() {
  #expect(worktree(status: status(), createdAt: today) == .active)
  #expect(worktree(status: status(date: lastMonth), createdAt: today) == .stale)
  #expect(worktree(status: status(pr: pr("MERGED")), createdAt: today, dirty: true) == .nearDead)
}

@Test func processInFolderBeatsMerged() {
  #expect(worktree(status: status(pr: pr("MERGED")), inUse: true) == .inUse)
}

@Test func openPRIsActiveRegardlessOfAge() {
  #expect(worktree(status: status(date: lastMonth, pr: pr("OPEN"))) == .active)
}

@Test func closedPRBehavesLikeNoPR() {
  #expect(worktree(status: status(date: lastMonth, pr: pr("CLOSED"))) == .stale)
  #expect(worktree(status: status(date: today, pr: pr("CLOSED"))) == .active)
}

@Test func freshBranchOnMainWithUncommittedWorkIsActive() {
  #expect(worktree(status: status(inBase: true), dirty: true) == .active)
}

@Test func detachedOnMainCommitIsDead() {
  #expect(worktree(status: status(inBase: true)) == .dead)
}

@Test func oldUnmergedCommitsAreStale() {
  #expect(worktree(status: status(date: lastMonth)) == .stale)
}

@Test func branchCheckedOutInWorktreeIsInUse() {
  #expect(Judge.branch(isBaseBranch: false, checkedOut: true, status: status(pr: pr("MERGED"))) == .inUse)
}

@Test func baseBranchIsMain() {
  #expect(Judge.branch(isBaseBranch: true, checkedOut: false, status: status()) == .main)
}

@Test func stashVerdicts() {
  #expect(Judge.stash(isLintStagedBackup: true, branchDeleted: false, inMain: false, date: today) == .dead)
  #expect(Judge.stash(isLintStagedBackup: false, branchDeleted: false, inMain: true, date: today) == .dead)
  #expect(Judge.stash(isLintStagedBackup: false, branchDeleted: true, inMain: false, date: today) == .nearDead)
  #expect(Judge.stash(isLintStagedBackup: false, branchDeleted: false, inMain: false, date: lastMonth) == .stale)
  #expect(Judge.stash(isLintStagedBackup: false, branchDeleted: false, inMain: false, date: today) == .active)
}

@Test func patchFitSummarisesPerFileFates() {
  #expect(PatchFit([]).label == "" && !PatchFit([]).allInMain && PatchFit([]).rank == 3)
  #expect(PatchFit([.inMain, .inMain]).label == "in main" && PatchFit([.inMain]).allInMain && PatchFit([.inMain]).rank == 0)
  #expect(PatchFit([.applies, .applies]).label == "not in main" && PatchFit([.applies]).rank == 2)
  #expect(PatchFit([.conflicts]).label == "conflicts" && PatchFit([.conflicts]).rank == 1)
  #expect(PatchFit([.inMain, .applies, .conflicts, .conflicts]).label == "1 of 4 in main")
  #expect(PatchFit([.inMain, .applies]).label == "1 of 2 in main")
}

@Test func verdictsSortWorstFirst() {
  #expect(Verdict.prunable < .dead && .dead < .nearDead && .nearDead < .stale && .stale < .inUse && .inUse < .active && .active < .main)
}
