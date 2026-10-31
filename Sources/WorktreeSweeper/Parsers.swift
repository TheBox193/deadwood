import Foundation

extension GitScanner {
  static func parseCommitDates(_ lines: [String]) -> [String: Date] {
    Dictionary(uniqueKeysWithValues: lines.compactMap { line in
      let parts = line.split(separator: " ")
      guard parts.count == 2, let date = Date(unixSeconds: String(parts[1])) else { return nil }
      return (String(parts[0]), date)
    })
  }

  static func parseWorktrees(_ porcelain: String) -> [Worktree] {
    var result: [Worktree] = []
    var path = "", head = "", branch: String?, prunable = false
    let flush = {
      guard !path.isEmpty else { return }
      result.append(Worktree(path: path, head: head, branch: branch, isMainCheckout: result.isEmpty, markedPrunable: prunable))
      path = ""; head = ""; branch = nil; prunable = false
    }
    for line in porcelain.components(separatedBy: "\n") {
      if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst(9)) }
      else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
      else if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst(18)) }
      else if line.hasPrefix("prunable") { prunable = true }
    }
    flush()
    return result
  }

  static func parseBranches(_ lines: [String], worktrees: [Worktree]) -> [LocalBranch] {
    let checkedOut = Dictionary(worktrees.compactMap { w in w.branch.map { ($0, w.path) } }, uniquingKeysWith: { a, _ in a })
    return lines.compactMap { line in
      let parts = line.components(separatedBy: "|")
      guard parts.count == 4 else { return nil }
      var b = LocalBranch(name: parts[0], head: parts[1], upstreamGone: parts[2] == "[gone]")
      b.worktreePath = checkedOut[parts[0]]
      b.status.lastCommitDate = Date(unixSeconds: parts[3]) ?? .distantPast
      return b
    }
  }

  static func parseStashes(_ lines: [String]) -> [Stash] {
    lines.compactMap { line in
      let parts = line.components(separatedBy: "|")
      guard parts.count >= 3, let date = Date(unixSeconds: parts[1]) else { return nil }
      let message = parts[2...].joined(separator: "|")
      return Stash(sha: parts[0], date: date, message: message, branch: stashBranch(message))
    }
  }

  static func stashBranch(_ message: String) -> String? {
    for prefix in ["WIP on ", "On "] where message.hasPrefix(prefix) {
      let rest = message.dropFirst(prefix.count)
      if let colon = rest.firstIndex(of: ":") { return String(rest[..<colon]) }
    }
    return nil
  }

  static func parseProcessCwds(_ lsofLines: [String]) -> [(command: String, path: String)] {
    var result: [(String, String)] = []
    var command = ""
    for line in lsofLines {
      if line.hasPrefix("c") { command = String(line.dropFirst()) }
      else if line.hasPrefix("n") { result.append((command, String(line.dropFirst()))) }
    }
    return result
  }
}
