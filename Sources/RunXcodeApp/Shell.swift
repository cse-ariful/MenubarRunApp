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

    /// Environment for child processes: your login shell's PATH / JAVA_HOME / ANDROID_HOME / FLUTTER_ROOT…
    /// (apps launched from Finder don't get them), plus common tool locations as a fallback.
    static var environment: [String: String] {
        var env = userEnvironment
        let home = NSHomeDirectory()
        var extra = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/development/flutter/bin", "\(home)/flutter/bin", "\(home)/fvm/default/bin",
            "\(home)/.pub-cache/bin", "\(home)/.local/bin",  // pipx (pymobiledevice3)
        ]
        if let sdk = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] ?? defaultAndroidSDK {
            env["ANDROID_HOME"] = sdk
            extra += ["\(sdk)/platform-tools", "\(sdk)/emulator"]
        }
        env["PATH"] = ([env["PATH"]].compactMap { $0 } + extra).joined(separator: ":")
        if env["JAVA_HOME"] == nil {
            // Android Studio's bundled JDK, so Gradle works without a separate Java install.
            for jbr in ["/Applications/Android Studio.app/Contents/jbr/Contents/Home",
                        "/Applications/Android Studio.app/Contents/jre/Contents/Home"]
            where FileManager.default.fileExists(atPath: jbr) {
                env["JAVA_HOME"] = jbr
                break
            }
        }
        env["NSUnbufferedIO"] = "YES"
        return env
    }

    private static var defaultAndroidSDK: String? {
        let path = NSHomeDirectory() + "/Library/Android/sdk"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Finds an executable on the PATH from `environment` (like `which`).
    static func which(_ name: String) -> String? {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in paths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Loaded once (lazily, thread-safe) from `$SHELL -l -i`, with a 5 s timeout.
    static let userEnvironment: [String: String] = loadLoginShellEnvironment()

    private static func loadLoginShellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let marker = "__RUNXCODEAPP_ENV__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\(marker)\\0'; /usr/bin/env -0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return env }

        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return env
        }

        let entries = box.data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let start = entries.firstIndex(where: { $0.hasSuffix(marker) }) else { return env }
        let wanted: Set<String> = ["PATH", "JAVA_HOME", "ANDROID_HOME", "ANDROID_SDK_ROOT",
                                   "FLUTTER_ROOT", "PUB_CACHE", "GRADLE_USER_HOME", "LANG", "LC_ALL"]
        for entry in entries[(start + 1)...] {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            if wanted.contains(key) || key.hasPrefix("ANDROID_") || key.hasPrefix("FLUTTER_") {
                env[key] = String(entry[entry.index(after: eq)...])
            }
        }
        return env
    }

    /// Runs a command to completion and collects stdout/stderr (read concurrently to avoid pipe deadlocks).
    static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil,
                    environment overrides: [String: String] = [:]) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = Shell.environment.merging(overrides) { $1 }
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
    private var input: Pipe?

    /// - Parameter interactive: keep stdin open so `send(_:)` can type into the process (e.g. Flutter's "r").
    func run(_ executable: String,
             _ arguments: [String],
             currentDirectory: URL? = nil,
             environment overrides: [String: String] = [:],
             interactive: Bool = false,
             onLine: @escaping (String) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            let pipe = Pipe()
            let handle = pipe.fileHandleForReading
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = Shell.environment.merging(overrides) { $1 }
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }
            process.standardOutput = pipe
            process.standardError = pipe
            if interactive {
                let stdin = Pipe()
                input = stdin
                process.standardInput = stdin
            } else {
                process.standardInput = FileHandle.nullDevice
            }

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

    /// Types text into an interactive process.
    func send(_ text: String) {
        guard process.isRunning, let input, let data = text.data(using: .utf8) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    var isRunning: Bool { process.isRunning }

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
