import Foundation

#if os(macOS)
  import Darwin
#else
  import Glibc
#endif

struct ProcessResult {
  let status: Int32
  let stdout: Data
  let stderr: Data

  var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
  var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessRunnerError: LocalizedError {
  case launchFailed(String)
  case timedOut(String)
  case outputDrainTimedOut(String)

  var errorDescription: String? {
    switch self {
    case .launchFailed(let message): return message
    case .timedOut(let command): return "命令逾時：\(command)"
    case .outputDrainTimedOut(let command): return "命令已結束，但輸出管線未能安全收尾：\(command)"
    }
  }
}

private final class ProcessDataBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  func store(_ data: Data) {
    lock.lock()
    storage = data
    lock.unlock()
  }

  func value() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

enum ProcessRunner {
  static func run(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 30)
    throws -> ProcessResult
  {
    let command = ([executable] + arguments).joined(separator: " ")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
    } catch {
      throw ProcessRunnerError.launchFailed("無法啟動 \(executable)：\(error.localizedDescription)")
    }

    // Drain both pipes while the command is running. Waiting for process exit before
    // reading can deadlock when a managed cleanup emits more than the pipe buffer.
    let stdoutBox = ProcessDataBox()
    let stderrBox = ProcessDataBox()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      stdoutBox.store(outputPipe.fileHandleForReading.readDataToEndOfFile())
      readers.leave()
    }
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      stderrBox.store(errorPipe.fileHandleForReading.readDataToEndOfFile())
      readers.leave()
    }

    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      process.waitUntilExit()
      exited.signal()
    }

    if exited.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if exited.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 5)
      }
      _ = readers.wait(timeout: .now() + 5)
      throw ProcessRunnerError.timedOut(command)
    }

    guard readers.wait(timeout: .now() + 10) == .success else {
      outputPipe.fileHandleForReading.closeFile()
      errorPipe.fileHandleForReading.closeFile()
      throw ProcessRunnerError.outputDrainTimedOut(command)
    }

    return ProcessResult(
      status: process.terminationStatus,
      stdout: stdoutBox.value(),
      stderr: stderrBox.value()
    )
  }
}
