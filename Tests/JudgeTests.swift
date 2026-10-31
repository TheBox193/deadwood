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

private func worktree(status s: BranchStatus, exists: Bool = true, prunable: Bool = false, inUse: Bool = false, dirty: Bool = false) -> Verdict {
  Judge.worktree(isMainCheckout: false, exists: exists, markedPrunable: prunable, inUse: inUse, dirty: dirty, status: s)
}

@Test func mainCheckoutIsAlwaysMain() {
  #expect(Judge.worktree(isMainCheckout: true, exists: true, markedPrunable: false, inUse: true, dirty: true, status: status()) == .main)
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

@Test func mergedButStashIsNearDead() {
  #expect(worktree(status: status(pr: pr("MERGED"), stashes: ["On b: wip"])) == .nearDead)
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
  #expect(Judge.stash(isLintStagedBackup: true, branchDeleted: false, date: today) == .dead)
  #expect(Judge.stash(isLintStagedBackup: false, branchDeleted: true, date: today) == .nearDead)
  #expect(Judge.stash(isLintStagedBackup: false, branchDeleted: false, date: lastMonth) == .stale)
  #expect(Judge.stash(isLintStagedBackup: false, branchDeleted: false, date: today) == .active)
}

@Test func verdictsSortWorstFirst() {
  #expect(Verdict.prunable < .dead && .dead < .nearDead && .nearDead < .stale && .stale < .inUse && .inUse < .active && .active < .main)
}
