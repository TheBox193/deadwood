import Foundation

enum Judge {
  static let staleAfterDays = 14
  static let staleStashAfterDays = 30
  static let justAddedWithin: TimeInterval = 24 * 60 * 60

  static func worktree(isMainCheckout: Bool, exists: Bool, markedPrunable: Bool, inUse: Bool, createdAt: Date?, dirty: Bool, status: BranchStatus) -> Verdict {
    if isMainCheckout { return .main }
    if !exists || markedPrunable { return .prunable }
    if inUse { return .inUse }
    if justAdded(createdAt, status: status) { return .active }
    if let v = merged(status, hasLeftovers: dirty) { return v }
    if status.fullyMerged { return dirty ? .active : .nearDead }
    return status.lastCommitDate.daysAgo > staleAfterDays ? .stale : .active
  }

  static func branch(isBaseBranch: Bool, checkedOut: Bool, status: BranchStatus) -> Verdict {
    if isBaseBranch { return .main }
    if checkedOut { return .inUse }
    if let v = merged(status, hasLeftovers: false) { return v }
    if status.fullyMerged { return .nearDead }
    return status.lastCommitDate.daysAgo > staleAfterDays ? .stale : .active
  }

  static func stash(isLintStagedBackup: Bool, branchDeleted: Bool, inMain: Bool, date: Date) -> Verdict {
    if isLintStagedBackup || inMain { return .dead }
    if branchDeleted { return .nearDead }
    return date.daysAgo > staleStashAfterDays ? .stale : .active
  }

  /// A folder made in the last day that has no commits of its own: someone set it up and has not started yet.
  static func justAdded(_ createdAt: Date?, status: BranchStatus) -> Bool {
    guard let createdAt, status.inBaseBranch else { return false }
    return Date().timeIntervalSince(createdAt) < justAddedWithin
  }

  private static func merged(_ s: BranchStatus, hasLeftovers: Bool) -> Verdict? {
    if s.pullRequest?.isOpen == true { return .active }
    if s.fullyMerged && !hasLeftovers { return .dead }
    if s.pullRequest?.isMerged == true { return .nearDead }
    return nil
  }
}
