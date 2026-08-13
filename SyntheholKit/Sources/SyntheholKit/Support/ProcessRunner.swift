import Foundation

/// An event emitted by a running child process.
public enum ProcessEvent: Sendable, Equatable {
    case launched(pid: Int32)
    case stdout(String)
    case stderr(String)
    case terminated(exitCode: Int32)
}

/// Collected result of a completed child process.
public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
}

public enum ProcessRunnerError: Error {
    case launchFailed(executable: URL, underlying: any Error)
}

/// Runs child processes with argv arrays — never shell strings — and exposes
/// their output as an async stream.
public enum ProcessRunner {
    /// Streams events from a child process. The stream finishes after `.terminated`.
    /// Cancelling the consuming task terminates the process.
    public static func stream(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) -> AsyncThrowingStream<ProcessEvent, any Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // Games are interactive: without this, macOS may schedule the wine
            // processes as background work and input latency suffers.
            process.qualityOfService = .userInitiated
            if let environment { process.environment = environment }
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    continuation.yield(.stdout(text))
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    continuation.yield(.stderr(text))
                }
            }

            process.terminationHandler = { finished in
                // Drain whatever the readability handlers haven't seen yet.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if let data = try? stdoutPipe.fileHandleForReading.readToEnd(),
                   !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    continuation.yield(.stdout(text))
                }
                if let data = try? stderrPipe.fileHandleForReading.readToEnd(),
                   !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    continuation.yield(.stderr(text))
                }
                continuation.yield(.terminated(exitCode: finished.terminationStatus))
                continuation.finish()
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
                continuation.yield(.launched(pid: process.processIdentifier))
            } catch {
                continuation.finish(throwing: ProcessRunnerError.launchFailed(
                    executable: executable, underlying: error
                ))
            }
        }
    }

    /// Runs a child process to completion and collects its output.
    /// Does not throw on nonzero exit — Wine tools exit nonzero routinely;
    /// callers inspect `exitCode` when it matters.
    public static func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) async throws -> ProcessResult {
        var stdout = ""
        var stderr = ""
        var exitCode: Int32 = -1
        for try await event in stream(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory
        ) {
            switch event {
            case .launched:
                break
            case .stdout(let text):
                stdout += text
            case .stderr(let text):
                stderr += text
            case .terminated(let code):
                exitCode = code
            }
        }
        return ProcessResult(exitCode: exitCode, standardOutput: stdout, standardError: stderr)
    }
}
