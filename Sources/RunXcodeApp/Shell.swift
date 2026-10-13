import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

enum ShellError: LocalizedError {
    case failed(command: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .failed(command, status, output):
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command) failed (exit \(status))" + (message.isEmpty ? "" : ": \(message)")
        }
    }
}

enum Shell {
    static let xcrunPath = "/usr/bin/xcrun"

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = [env["PATH"], extra].compactMap { $0 }.joined(separator: ":")
        env["NSUnbufferedIO"] = "YES"
        return env
    }

    /// Runs a command to completion and collects stdout/stderr (read concurrently to avoid pipe deadlocks).
    static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = Shell.environment
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: ShellResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self)
                ))
            }
        }
    }

    /// Same as `run`, but throws when the exit status is non-zero.
    @discardableResult
    static func checked(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) async throws -> ShellResult {
        let result = try await run(executable, arguments, currentDirectory: currentDirectory)
        guard result.succeeded else {
            let name = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments.prefix(2)).joined(separator: " ")
            throw ShellError.failed(command: name, status: result.status, output: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Thread-safe line queue; the UI drains it on a timer so verbose builds don't flood SwiftUI.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let drained = lines
        lines.removeAll(keepingCapacity: true)
        return drained
    }
}

/// Runs a long process (xcodebuild) and emits its merged stdout/stderr line by line.
final class StreamingProcess: @unchecked Sendable {
    private let process = Process()
    private let queue = DispatchQueue(label: "RunXcodeApp.StreamingProcess")
    private var pending = Data()

    func run(_ executable: String,
             _ arguments: [String],
             currentDirectory: URL? = nil,
             onLine: @escaping (String) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            let pipe = Pipe()
            let handle = pipe.fileHandleForReading
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = Shell.environment
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                guard !data.isEmpty else { return }
                self.queue.async { self.consume(data, onLine: onLine) }
            }

            process.terminationHandler = { finished in
                handle.readabilityHandler = nil
                let rest = handle.readDataToEndOfFile()
                let status = finished.terminationStatus
                self.queue.async {
                    self.consume(rest, onLine: onLine)
                    if !self.pending.isEmpty {
                        onLine(String(decoding: self.pending, as: UTF8.self))
                        self.pending.removeAll()
                    }
                    self.process.terminationHandler = nil
                    continuation.resume(returning: status)
                }
            }

            do {
                try process.run()
            } catch {
                handle.readabilityHandler = nil
                process.terminationHandler = nil
                onLine("Failed to launch \(executable): \(error.localizedDescription)")
                continuation.resume(returning: -1)
            }
        }
    }

    /// SIGINT – lets xcodebuild cancel cleanly.
    func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data, onLine: (String) -> Void) {
        guard !data.isEmpty else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            onLine(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
    }
}
