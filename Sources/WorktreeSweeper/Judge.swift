import Foundation

enum Judge {
  static let staleAfterDays = 14
  static let staleStashAfterDays = 30

  static func worktree(isMainCheckout: Bool, exists: Bool, markedPrunable: Bool, inUse: Bool, dirty: Bool, status: BranchStatus) -> Verdict {
    if isMainCheckout { return .main }
    if !exists || markedPrunable { return .prunable }
    if inUse { return .inUse }
    if let v = merged(status, hasLeftovers: dirty || !status.stashes.isEmpty) { return v }
    if status.fullyMerged { return dirty ? .active : .nearDead }
    return status.lastCommitDate.daysAgo > staleAfterDays ? .stale : .active
  }

  static func branch(isBaseBranch: Bool, checkedOut: Bool, status: BranchStatus) -> Verdict {
    if isBaseBranch { return .main }
    if checkedOut { return .inUse }
    if let v = merged(status, hasLeftovers: !status.stashes.isEmpty) { return v }
    if status.fullyMerged { return .nearDead }
    return status.lastCommitDate.daysAgo > staleAfterDays ? .stale : .active
  }

  static func stash(isLintStagedBackup: Bool, branchDeleted: Bool, date: Date) -> Verdict {
    if isLintStagedBackup { return .dead }
    if branchDeleted { return .nearDead }
    return date.daysAgo > staleStashAfterDays ? .stale : .active
  }

  private static func merged(_ s: BranchStatus, hasLeftovers: Bool) -> Verdict? {
    if s.pullRequest?.isOpen == true { return .active }
    if s.fullyMerged && !hasLeftovers { return .dead }
    if s.pullRequest?.isMerged == true { return .nearDead }
    return nil
  }
}
