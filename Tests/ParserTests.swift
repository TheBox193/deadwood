import Foundation
import Testing
@testable import WorktreeSweeper

@Test func worktreePorcelainParsesMainDetachedAndPrunable() {
  let porcelain = """
  worktree /Users/me/Code/repo
  HEAD 1111111111111111111111111111111111111111
  branch refs/heads/main

  worktree /Users/me/Code/repo/.claude/worktrees/thing
  HEAD 2222222222222222222222222222222222222222
  detached

  worktree /Users/me/Code/gone
  HEAD 3333333333333333333333333333333333333333
  branch refs/heads/feature/x
  prunable gitdir file points to non-existent location

  """
  let wts = Auditor.parseWorktrees(porcelain)
  #expect(wts.count == 3)
  #expect(wts[0].isMainCheckout && wts[0].branch == "main")
  #expect(!wts[1].isMainCheckout && wts[1].branch == nil && wts[1].branchLabel == "detached @ 2222222")
  #expect(wts[2].branch == "feature/x" && wts[2].markedPrunable)
}

@Test func branchLinesCarryGoneUpstreamAndWorktreePath() {
  let wts = Auditor.parseWorktrees("worktree /repo\nHEAD aaa\nbranch refs/heads/main\n\nworktree /wt\nHEAD bbb\nbranch refs/heads/feat\n")
  let branches = Auditor.parseBranches(["main|aaa||1700000000", "feat|bbb|[gone]|1700000001", "other|ccc|[ahead 1]|1700000002", "malformed"], worktrees: wts)
  #expect(branches.map(\.name) == ["main", "feat", "other"])
  #expect(branches[1].upstreamGone && branches[1].worktreePath == "/wt")
  #expect(!branches[2].upstreamGone && branches[2].worktreePath == nil)
  #expect(branches[2].status.lastCommitDate == Date(timeIntervalSince1970: 1_700_000_002))
}

@Test func commitDateLinesMapShaToDate() {
  let dates = Auditor.parseCommitDates(["aaa 1700000000", "bbb 1700000001", "junk"])
  #expect(dates["aaa"] == Date(timeIntervalSince1970: 1_700_000_000) && dates["bbb"] != nil && dates.count == 2)
}

@Test func stashLinesKeepPipesInMessagesAndFindTheBranch() {
  let stashes = Auditor.parseStashes([
    "abc|1700000000|WIP on feat/x: 1234567 Merge a|b",
    "def|1700000001|On main: brb",
    "ghi|1700000002|lint-staged automatic backup",
    "bad line",
  ])
  #expect(stashes.count == 3)
  #expect(stashes[0].branch == "feat/x" && stashes[0].message.hasSuffix("Merge a|b"))
  #expect(stashes[1].branch == "main")
  #expect(stashes[2].branch == nil && stashes[2].isLintStagedBackup)
  #expect(stashes[0].date == Date(timeIntervalSince1970: 1_700_000_000))
}

@Test func lsofFieldsPairCommandsWithDirectories() {
  let cwds = Auditor.parseProcessCwds(["p123", "cclaude", "n/repo/wt-a", "p456", "czsh", "n/repo/wt-b", "p789", "cnode", "n/elsewhere"])
  #expect(cwds.map(\.command) == ["claude", "zsh", "node"])
  #expect(cwds.map(\.path) == ["/repo/wt-a", "/repo/wt-b", "/elsewhere"])
}
