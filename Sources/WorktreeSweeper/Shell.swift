import Foundation

struct ShellResult {
  let status: Int32
  let stdout: String
  let stderr: String
  var ok: Bool { status == 0 }
  var lines: [String] { stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

enum Shell {
  static func run(_ command: String, _ args: [String], cwd: String? = nil) -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
    process.environment = env
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch {
      return ShellResult(status: 127, stdout: "", stderr: error.localizedDescription)
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ShellResult(
      status: process.terminationStatus,
      stdout: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .newlines),
      stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  static func git(_ args: [String], in dir: String) -> ShellResult { run("git", ["-C", dir] + args) }
}
