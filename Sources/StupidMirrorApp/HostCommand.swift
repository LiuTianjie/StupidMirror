import Darwin
import Foundation

/// Runs a host tool (adb, xcrun) with a deadline, collecting stdout and
/// stderr separately so a chatty tool can't fill one pipe and stall.
enum HostCommand {
    struct Result: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        /// stderr if the tool wrote any, else stdout, else the exit status.
        var message: String {
            let stderr = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(decoding: stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "Exited with status \(status).")
        }
    }

    enum Failure: Error, Equatable {
        case launchFailed(String)
        case timedOut
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()

        func setStdout(_ data: Data) {
            lock.withLock { stdout = data }
        }

        func setStderr(_ data: Data) {
            lock.withLock { stderr = data }
        }

        func snapshot() -> (stdout: Data, stderr: Data) {
            lock.withLock { (stdout, stderr) }
        }
    }

    static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> Result {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exitSemaphore = DispatchSemaphore(value: 0)
        let readGroup = DispatchGroup()
        let output = OutputBox()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            output.setStdout(data)
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            output.setStderr(data)
            readGroup.leave()
        }
        process.terminationHandler = { _ in exitSemaphore.signal() }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw Failure.launchFailed(error.localizedDescription)
        }

        if exitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exitSemaphore.wait(timeout: .now() + 0.75) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSemaphore.wait(timeout: .now() + 1)
            }
            _ = readGroup.wait(timeout: .now() + 1)
            throw Failure.timedOut
        }
        _ = readGroup.wait(timeout: .now() + 2)
        let captured = output.snapshot()
        return Result(
            status: process.terminationStatus,
            stdout: captured.stdout,
            stderr: captured.stderr
        )
    }

    /// `run` on a dispatch thread, so a long tool (a build, an install) never
    /// holds one of Swift concurrency's few cooperative threads.
    static func runDetached(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Swift.Result { try run(executable, arguments: arguments, timeout: timeout) })
            }
        }
    }
}
