import AppKit
import Foundation

enum RunError: LocalizedError {
    case buildFailed(status: Int32, firstError: String?)
    case productNotFound(detail: String?)

    var errorDescription: String? {
        switch self {
        case let .buildFailed(status, firstError):
            if let firstError { return "Build failed: \(firstError)" }
            return "Build failed (xcodebuild exit \(status)). Open the log for details."
        case let .productNotFound(detail):
            let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = trimmed.isEmpty ? "" : ": \(trimmed)"
            return "Couldn't find a built .app for this scheme. Is it an application scheme?" + suffix
        }
    }
}

/// Builds the selected scheme with xcodebuild, then installs and launches it on the chosen simulator.
@MainActor
final class BuildRunner: ObservableObject {
    @Published private(set) var phase: RunPhase = .idle
    @Published private(set) var logLines: [String] = []
    @Published private(set) var logRevision = 0
    @Published private(set) var statusDetail = ""
    @Published private(set) var warningCount = 0
    @Published private(set) var errorCount = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var runDescription = ""
    /// The project the current / most recent run belongs to.
    @Published private(set) var projectID: String?

    let logURL: URL

    private var firstError: String?
    private var logHandle: FileHandle?
    private var currentProcess: StreamingProcess?
    private var runTask: Task<Void, Never>?
    private var flushTimer: Timer?
    private let pending = LineBuffer()
    private let maxVisibleLines = 2000

    init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/RunXcodeApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("last-run.log")
    }

    var isRunning: Bool { phase.isActive }

    func run(project: XcodeProject, scheme: String, simulator: Simulator, configuration: String = "Debug") {
        guard !isRunning else { return }
        beginLog()
        projectID = project.id
        runDescription = "\(project.displayName) · \(scheme) → \(simulator.name) (\(simulator.runtimeName))"
        startedAt = Date()
        finishedAt = nil
        phase = .building

        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushPending() }
        }
        runTask = Task { [weak self] in
            await self?.perform(project: project, scheme: scheme, simulator: simulator, configuration: configuration)
        }
    }

    func stop() {
        guard isRunning else { return }
        runTask?.cancel()
        let process = currentProcess
        process?.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { process?.terminate() }
    }

    // MARK: - Pipeline

    private func perform(project: XcodeProject, scheme: String, simulator: Simulator, configuration: String) async {
        append("▶ \(scheme) (\(configuration)) on \(simulator.name) — \(simulator.runtimeName)")
        append("  \(project.url.path)")

        let udid = simulator.udid
        let isDevice = simulator.isPhysical
        // Boot the simulator in parallel with the build to save time (not needed for real devices).
        let bootTask: Task<ShellResult, Error>? = isDevice ? nil : Task.detached { () -> ShellResult in
            try await Shell.run(Shell.xcrunPath, ["simctl", "bootstatus", udid, "-b"])
        }

        do {
            let base = [
                "xcodebuild", project.containerFlag, project.url.path,
                "-scheme", scheme,
                "-configuration", configuration,
                "-destination", "id=\(udid)",
            ]

            var buildArguments = base + ["-skipPackagePluginValidation", "-skipMacroValidation"]
            if isDevice {
                // Let Xcode create/refresh provisioning profiles (automatic signing).
                buildArguments += ["-allowProvisioningUpdates"]
            }

            phase = .building
            let status = await stream(buildArguments + ["build"], in: project.directory)
            try Task.checkCancellation()
            guard status == 0 else { throw RunError.buildFailed(status: status, firstError: firstError) }

            phase = .preparing
            let product = try await locateProduct(base: base, scheme: scheme, in: project.directory)
            append("App: \(product.appURL.path)")
            append("Bundle ID: \(product.bundleIdentifier)")
            try Task.checkCancellation()

            if isDevice {
                phase = .installing
                try await logged(["devicectl", "device", "install", "app", "--device", udid, product.appURL.path])
                try Task.checkCancellation()

                phase = .launching
                try await logged(["devicectl", "device", "process", "launch", "--device", udid,
                                  "--terminate-existing", product.bundleIdentifier])
            } else {
                phase = .booting
                if let bootTask {
                    let boot = try await bootTask.value
                    guard boot.succeeded else {
                        throw ShellError.failed(command: "simctl bootstatus", status: boot.status,
                                                output: boot.stderr.isEmpty ? boot.stdout : boot.stderr)
                    }
                }
                await SimulatorStore.openSimulatorApp(udid: udid)
                try Task.checkCancellation()

                phase = .installing
                try await logged(["simctl", "install", udid, product.appURL.path])
                try Task.checkCancellation()

                phase = .launching
                try await logged(["simctl", "launch", "--terminate-running-process", udid, product.bundleIdentifier])
            }
            append("✓ Launched \(product.bundleIdentifier) on \(simulator.name)")
            phase = .succeeded
        } catch {
            if error is CancellationError || Task.isCancelled {
                append("■ Stopped")
                phase = .cancelled
            } else {
                append("✗ \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
        }
        finish()
    }

    private func stream(_ arguments: [String], in directory: URL) async -> Int32 {
        append("$ xcrun " + arguments.map(Self.shellQuote).joined(separator: " "))
        let process = StreamingProcess()
        currentProcess = process
        let buffer = pending
        let status = await process.run(Shell.xcrunPath, arguments, currentDirectory: directory) { line in
            buffer.append(line)
        }
        currentProcess = nil
        flushPending()
        return status
    }

    @discardableResult
    private func logged(_ arguments: [String]) async throws -> ShellResult {
        append("$ xcrun " + arguments.map(Self.shellQuote).joined(separator: " "))
        let result = try await Shell.run(Shell.xcrunPath, arguments)
        for line in (result.stdout + result.stderr).split(whereSeparator: \.isNewline) {
            append(String(line))
        }
        guard result.succeeded else {
            throw ShellError.failed(command: arguments.prefix(2).joined(separator: " "),
                                    status: result.status,
                                    output: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    // MARK: - Locating the built app

    private struct BuiltProduct {
        let appURL: URL
        let bundleIdentifier: String
    }

    private struct SettingsEntry: Decodable {
        let target: String?
        let buildSettings: [String: String]
    }

    private func locateProduct(base: [String], scheme: String, in directory: URL) async throws -> BuiltProduct {
        append("Reading build settings…")
        let result = try await Shell.run(Shell.xcrunPath, base + ["-showBuildSettings", "-json"], currentDirectory: directory)
        let output = result.stdout
        guard let start = output.range(of: "[\n")?.lowerBound ?? output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"), start < end else {
            throw RunError.productNotFound(detail: result.stderr)
        }
        let entries = try JSONDecoder().decode([SettingsEntry].self, from: Data(output[start...end].utf8))

        // Prefer the target named like the scheme; skip non-app products (frameworks, tests…).
        let apps = entries
            .filter { $0.buildSettings["WRAPPER_EXTENSION"] == "app" }
            .sorted { ($0.target == scheme ? 0 : 1) < ($1.target == scheme ? 0 : 1) }

        for entry in apps {
            let settings = entry.buildSettings
            guard let dir = settings["TARGET_BUILD_DIR"], let name = settings["FULL_PRODUCT_NAME"] else { continue }
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let identifier = Self.bundleIdentifier(of: url) ?? settings["PRODUCT_BUNDLE_IDENTIFIER"] {
                return BuiltProduct(appURL: url, bundleIdentifier: identifier)
            }
        }
        throw RunError.productNotFound(detail: nil)
    }

    nonisolated static func bundleIdentifier(of app: URL) -> String? {
        for plist in [app.appendingPathComponent("Info.plist"), app.appendingPathComponent("Contents/Info.plist")] {
            guard let data = try? Data(contentsOf: plist),
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = object as? [String: Any],
                  let identifier = dictionary["CFBundleIdentifier"] as? String else { continue }
            return identifier
        }
        return nil
    }

    // MARK: - Logging

    private func beginLog() {
        _ = pending.drain()
        logLines = []
        logRevision += 1
        warningCount = 0
        errorCount = 0
        firstError = nil
        statusDetail = ""
        try? logHandle?.close()
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
    }

    private func finish() {
        flushPending()
        flushTimer?.invalidate()
        flushTimer = nil
        try? logHandle?.close()
        logHandle = nil
        currentProcess = nil
        runTask = nil
        finishedAt = Date()
    }

    private func flushPending() {
        let lines = pending.drain()
        guard !lines.isEmpty else { return }
        for line in lines { ingest(line) }
        logRevision += 1
    }

    private func append(_ line: String) {
        flushPending()
        ingest(line)
        logRevision += 1
    }

    private func ingest(_ raw: String) {
        let line = raw.replacingOccurrences(of: "\r", with: "")
        if let data = (line + "\n").data(using: .utf8) {
            try? logHandle?.write(contentsOf: data)
        }

        logLines.append(line)
        if logLines.count > maxVisibleLines + 200 {
            logLines.removeFirst(logLines.count - maxVisibleLines)
        }

        if line.contains(": error:") || line.hasPrefix("error:") {
            errorCount += 1
            if firstError == nil { firstError = line.trimmingCharacters(in: .whitespaces) }
        } else if line.contains(": warning:") || line.hasPrefix("warning:") {
            warningCount += 1
        } else if let summary = Self.progressSummary(for: line) {
            statusDetail = summary
        }
    }

    private static let progressVerbs: Set<String> = [
        "SwiftCompile", "CompileSwift", "CompileSwiftSources", "CompileC", "Ld", "CodeSign",
        "CompileAssetCatalog", "CompileStoryboard", "CompileXIB", "LinkStoryboards",
        "ProcessInfoPlistFile", "SwiftEmitModule", "SwiftDriver", "CopySwiftLibs",
        "GenerateDSYMFile", "ProcessProductPackaging", "PhaseScriptExecution", "Copy",
        "CpResource", "Touch", "Validate", "RegisterExecutionPolicyException",
    ]

    static func progressSummary(for line: String) -> String? {
        if line.hasPrefix("** ") { return line }
        if line.hasPrefix("Resolve Package Graph") || line.hasPrefix("Fetching") || line.hasPrefix("Resolved source packages") {
            return String(line.prefix(90))
        }
        let tokens = line.split(separator: " ")
        guard let verb = tokens.first.map(String.init), progressVerbs.contains(verb) else { return nil }
        let file = tokens.last(where: { $0.contains("/") })
            .map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? ""
        return file.isEmpty ? verb : "\(verb) \(file)"
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        let special = CharacterSet(charactersIn: " \"'$`\\()&;|<>*?![]{}")
        guard value.rangeOfCharacter(from: special) != nil else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
