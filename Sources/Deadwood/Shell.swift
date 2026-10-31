import Foundation

struct ShellResult: Sendable {
  let status: Int32
  let stdout: String
  let stderr: String
  var ok: Bool { status == 0 }
  var lines: [String] { stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
}

enum Shell {
  static func run(_ command: String, _ args: [String], cwd: String? = nil, env extra: [String: String] = [:]) async -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GH_PROMPT_DISABLED"] = "1"
    env["GIT_OPTIONAL_LOCKS"] = "0"
    if env["GIT_SSH_COMMAND"] == nil { env["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes" }
    env.merge(extra) { _, new in new }
    process.environment = env
    let out = PipeReader(), err = PipeReader()
    process.standardOutput = out.pipe
    process.standardError = err.pipe

    return await withCheckedContinuation { continuation in
      let done = DispatchGroup()
      done.enter()
      process.terminationHandler = { _ in done.leave() }
      do { try process.run() } catch {
        process.terminationHandler = nil
        done.leave()
        return continuation.resume(returning: ShellResult(status: 127, stdout: "", stderr: error.localizedDescription))
      }
      out.start(done)
      err.start(done)
      done.notify(queue: .global()) {
        continuation.resume(returning: ShellResult(
          status: process.terminationStatus,
          stdout: out.text.trimmingCharacters(in: .newlines),
          stderr: err.text.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
      }
    }
  }

  static func git(_ args: [String], in dir: String, env: [String: String] = [:]) async -> ShellResult {
    await run("git", ["-C", dir] + args, env: env)
  }
}

private final class PipeReader: @unchecked Sendable {
  let pipe = Pipe()
  private var data = Data()
  private let lock = NSLock()

  var text: String {
    lock.lock(); defer { lock.unlock() }
    return String(decoding: data, as: UTF8.self)
  }

  func start(_ group: DispatchGroup) {
    group.enter()
    pipe.fileHandleForReading.readabilityHandler = { [self] handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        group.leave()
      } else {
        lock.lock(); data.append(chunk); lock.unlock()
      }
    }
  }
}
