import AppKit
import Foundation

enum RunError: LocalizedError {
    case buildFailed(status: Int32, firstError: String?)
    case productNotFound(detail: String?)
    case missingScheme
    case toolMissing(String)

    var errorDescription: String? {
        switch self {
        case .missingScheme:
            return "Select a scheme first."
        case let .toolMissing(message):
            return message
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
    /// True while `flutter run` is attached (stdin open for r / R / q).
    private var isFlutterSession = false

    init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/RunXcodeApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("last-run.log")
    }

    var isRunning: Bool { phase.isActive }

    func run(project: XcodeProject, scheme: String?, simulator: Simulator, configuration: String = "Debug") {
        guard !isRunning else { return }
        beginLog()
        projectID = project.id
        runDescription = "\(project.displayName) · \(scheme ?? project.kindLabel) → \(simulator.name) (\(simulator.runtimeName))"
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
        if isFlutterSession {
            // Ask flutter to quit (stops the app too), then fall back to signals.
            process?.send("q")
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { process?.interrupt() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { process?.terminate() }
        } else {
            process?.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { process?.terminate() }
        }
    }

    // MARK: - Flutter hot reload

    var canHotReload: Bool { phase == .attached }

    func hotReload() {
        guard canHotReload else { return }
        append("↻ Hot reload")
        currentProcess?.send("r")
    }

    func hotRestart() {
        guard canHotReload else { return }
        append("⟲ Hot restart")
        currentProcess?.send("R")
    }

    // MARK: - Pipeline

    private func perform(project: XcodeProject, scheme: String?, simulator: Simulator, configuration: String) async {
        append("▶ \(scheme ?? project.kindLabel) (\(configuration)) on \(simulator.name) — \(simulator.runtimeName)")
        append("  \(project.url.path)")

        do {
            switch project.kind {
            case .workspace, .project:
                guard let scheme else { throw RunError.missingScheme }
                try await runXcode(project: project, scheme: scheme, simulator: simulator, configuration: configuration)
            case .flutter:
                try await runFlutter(project: project, destination: simulator)
            case .android:
                try await runAndroid(project: project, destination: simulator)
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                append("■ Stopped")
                phase = .cancelled
            } else {
                append("✗ \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
        }
        isFlutterSession = false
        finish()
    }

    // MARK: Xcode

    private func runXcode(project: XcodeProject, scheme: String, simulator: Simulator, configuration: String) async throws {
        let udid = simulator.udid
        let isDevice = simulator.kind == .device
        // Boot the simulator in parallel with the build to save time (not needed for real devices).
        let bootTask: Task<ShellResult, Error>? = isDevice ? nil : Task.detached { () -> ShellResult in
            try await Shell.run(Shell.xcrunPath, ["simctl", "bootstatus", udid, "-b"])
        }

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
        let status = await stream(Shell.xcrunPath, buildArguments + ["build"], in: project.directory, display: "xcrun")
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
    }

    // MARK: Flutter

    private func runFlutter(project: XcodeProject, destination: Simulator) async throws {
        guard let flutter = Shell.which("flutter") else {
            throw RunError.toolMissing("Flutter SDK not found. Make sure `flutter` is on the PATH in your shell profile (e.g. ~/.zshrc).")
        }

        phase = .booting
        let deviceID: String
        switch destination.kind {
        case .simulator:
            let boot = try await Shell.run(Shell.xcrunPath, ["simctl", "bootstatus", destination.udid, "-b"])
            guard boot.succeeded else {
                throw ShellError.failed(command: "simctl bootstatus", status: boot.status,
                                        output: boot.stderr.isEmpty ? boot.stdout : boot.stderr)
            }
            await SimulatorStore.openSimulatorApp(udid: destination.udid)
            deviceID = destination.udid
        case .device:
            deviceID = destination.udid
        case .androidEmulator, .androidDevice:
            if destination.serial == nil { append("Starting emulator \(destination.name)…") }
            deviceID = try await AndroidSDK.ensureOnline(destination)
        }
        try Task.checkCancellation()

        phase = .building
        isFlutterSession = true
        let status = await stream(flutter, ["run", "-d", deviceID, "--debug"],
                                  in: project.directory, display: "flutter", interactive: true)
        isFlutterSession = false
        try Task.checkCancellation()
        guard status == 0 else { throw RunError.buildFailed(status: status, firstError: firstError) }
        append("Flutter session ended")
        phase = .cancelled
    }

    // MARK: Android

    private func runAndroid(project: XcodeProject, destination: Simulator) async throws {
        guard let adb = AndroidSDK.adb else { throw AndroidError.sdkNotFound }
        let module = project.androidModule ?? "app"
        let gradlew = project.url.appendingPathComponent("gradlew").path
        guard FileManager.default.fileExists(atPath: gradlew) else {
            throw RunError.toolMissing("No gradlew in \(project.name). Open it in Android Studio once to create the Gradle wrapper.")
        }

        phase = .booting
        if destination.serial == nil { append("Starting emulator \(destination.name)…") }
        let serial = try await AndroidSDK.ensureOnline(destination)
        append("Device: \(serial)")
        try Task.checkCancellation()

        phase = .building
        let status = await stream("/bin/sh", [gradlew, ":\(module):installDebug", "--console=plain"],
                                  in: project.url, environment: ["ANDROID_SERIAL": serial],
                                  display: "./gradlew :\(module):installDebug --console=plain", showArguments: false)
        try Task.checkCancellation()
        guard status == 0 else { throw RunError.buildFailed(status: status, firstError: firstError) }

        phase = .launching
        let applicationID = try Self.androidApplicationID(project: project, module: module)
        append("Application ID: \(applicationID)")
        _ = try? await Shell.run(adb, ["-s", serial, "shell", "am", "force-stop", applicationID])
        try await logged(["-s", serial, "shell", "monkey", "-p", applicationID,
                          "-c", "android.intent.category.LAUNCHER", "1"], executable: adb, display: "adb")
        append("✓ Launched \(applicationID) on \(destination.name)")
        phase = .succeeded
    }

    /// Reads the applicationId from the build output (AGP 4.1+), falling back to the module's build script.
    nonisolated static func androidApplicationID(project: XcodeProject, module: String) throws -> String {
        let metadata = project.url.appendingPathComponent("\(module)/build/outputs/apk/debug/output-metadata.json")
        if let data = try? Data(contentsOf: metadata),
           let object = try? JSONSerialization.jsonObject(with: data),
           let json = object as? [String: Any],
           let id = json["applicationId"] as? String {
            return id
        }
        for file in ["build.gradle.kts", "build.gradle"] {
            let url = project.url.appendingPathComponent("\(module)/\(file)")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let id = firstMatch(#"applicationId\s*=?\s*["']([^"']+)["']"#, in: text) { return id }
            if let id = firstMatch(#"namespace\s*=?\s*["']([^"']+)["']"#, in: text) { return id }
        }
        throw RunError.toolMissing("Couldn't find the applicationId for \(project.name).")
    }

    nonisolated private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Process helpers

    private func stream(_ executable: String, _ arguments: [String], in directory: URL,
                        environment: [String: String] = [:], display: String,
                        showArguments: Bool = true, interactive: Bool = false) async -> Int32 {
        let shown = showArguments ? ([display] + arguments.map(Self.shellQuote)).joined(separator: " ") : display
        append("$ " + shown)
        let process = StreamingProcess()
        currentProcess = process
        let buffer = pending
        let status = await process.run(executable, arguments, currentDirectory: directory,
                                       environment: environment, interactive: interactive) { line in
            buffer.append(line)
        }
        currentProcess = nil
        flushPending()
        return status
    }

    @discardableResult
    private func logged(_ arguments: [String], executable: String = Shell.xcrunPath, display: String = "xcrun") async throws -> ShellResult {
        append("$ \(display) " + arguments.map(Self.shellQuote).joined(separator: " "))
        let result = try await Shell.run(executable, arguments)
        for line in (result.stdout + result.stderr).split(whereSeparator: \.isNewline) {
            append(String(line))
        }
        guard result.succeeded else {
            throw ShellError.failed(command: "\(display) " + arguments.prefix(2).joined(separator: " "),
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

        if isFlutterSession, phase != .attached, Self.isFlutterAttachedLine(line) {
            phase = .attached
            statusDetail = "r = hot reload · R = hot restart"
        }

        if line.contains(": error:") || line.hasPrefix("error:") || line.contains(": Error:") || line.hasPrefix("e: ") {
            errorCount += 1
            if firstError == nil { firstError = line.trimmingCharacters(in: .whitespaces) }
        } else if line.contains(": warning:") || line.hasPrefix("warning:") || line.hasPrefix("w: ") {
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

    private static func isFlutterAttachedLine(_ line: String) -> Bool {
        line.contains("Flutter run key commands") || line.contains("To hot reload")
            || line.contains("Dart VM Service") || line.contains("is available at: http")
    }

    static func progressSummary(for line: String) -> String? {
        if line.hasPrefix("** ") { return line }
        // Flutter / Gradle progress
        let flutterPrefixes = ["Launching lib/", "Running Gradle task", "Running Xcode build", "Running pod install",
                               "Xcode build done", "Syncing files", "Installing build", "Reloaded ", "Restarted application",
                               "Performing hot", "> Task :", "BUILD SUCCESSFUL", "BUILD FAILED", "Installed on"]
        if flutterPrefixes.contains(where: { line.hasPrefix($0) }) {
            return String(line.prefix(90))
        }
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
