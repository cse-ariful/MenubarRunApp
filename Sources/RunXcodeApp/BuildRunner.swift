import AppKit
import Combine
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

/// Owns one `RunSession` per project so several projects can build and run at the same time.
@MainActor
final class BuildRunner: ObservableObject {
    @Published private(set) var sessions: [String: RunSession] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]
    private var quitObserver: NSObjectProtocol?

    init() {
        // Don't leave dev servers running (and holding their ports) after the app quits.
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessions.values.forEach { $0.terminateWebServerNow() }
            }
        }
    }

    let logsDirectory: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/RunXcodeApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }()

    func session(for projectID: String) -> RunSession? { sessions[projectID] }

    func isRunning(_ projectID: String) -> Bool { sessions[projectID]?.isRunning ?? false }

    var runningCount: Int { sessions.values.filter(\.isRunning).count }

    /// Sessions still building / installing / launching (not just streaming an app's logs).
    var buildingCount: Int { sessions.values.filter { $0.phase.isBuilding }.count }

    func run(project: XcodeProject, scheme: String?, simulator: Simulator, options: RunOptions) {
        session(ensuring: project).run(project: project, scheme: scheme, simulator: simulator, options: options)
    }

    /// Starts a web project's dev server with `command` (run in the project folder).
    func runWeb(project: XcodeProject, command: String, options: RunOptions) {
        session(ensuring: project).runWeb(project: project, command: command, options: options)
    }

    /// The project's session, created on first use (tools can run before the first Run).
    func session(ensuring project: XcodeProject) -> RunSession {
        sessions[project.id] ?? makeSession(for: project)
    }

    func stop(_ projectID: String) { sessions[projectID]?.stop() }

    func stopAll() { sessions.values.forEach { $0.stop() } }

    /// Phase for the menu bar icon: busy if anything runs, otherwise the most recently finished run.
    var aggregatePhase: RunPhase {
        if sessions.values.contains(where: { $0.phase.isBuilding }) { return .building }
        if sessions.values.contains(where: { $0.phase == .streaming }) { return .streaming }
        let latest = sessions.values
            .filter { $0.finishedAt != nil }
            .max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
        return latest?.phase ?? .idle
    }

    private func makeSession(for project: XcodeProject) -> RunSession {
        let session = RunSession(projectID: project.id, logURL: logsDirectory.appendingPathComponent(Self.logFileName(for: project)))
        sessions[project.id] = session
        // Re-render rows / menu bar icon whenever any session changes.
        subscriptions[project.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return session
    }

    /// Stable per-project log name, e.g. "MyApp-1a2b3c4d.log".
    private static func logFileName(for project: XcodeProject) -> String {
        var hash: UInt32 = 5381
        for byte in project.id.utf8 { hash = (hash &<< 5) &+ hash &+ UInt32(byte) }
        let safeName = project.name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return "\(safeName)-\(String(hash, radix: 16)).log"
    }
}

/// One project's build / install / launch (or `flutter run`) session, with its own log and status.
@MainActor
final class RunSession: ObservableObject {
    @Published private(set) var phase: RunPhase = .idle
    @Published private(set) var logLines: [String] = []
    @Published private(set) var logRevision = 0
    @Published private(set) var statusDetail = ""
    @Published private(set) var warningCount = 0
    @Published private(set) var errorCount = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var runDescription = ""
    let projectID: String
    let logURL: URL

    private var firstError: String?
    private var logHandle: FileHandle?
    private var currentProcess: StreamingProcess?
    private var runTask: Task<Void, Never>?
    private var flushTimer: Timer?
    private let pending = LineBuffer()
    /// Lines kept in memory for the log window (the log file has everything).
    private let maxVisibleLines = 5000
    /// True while `flutter run` is attached (stdin open for r / R / q).
    private var isFlutterSession = false

    init(projectID: String, logURL: URL) {
        self.projectID = projectID
        self.logURL = logURL
    }

    var isRunning: Bool { phase.isActive }

    /// The app launched by the last run, for Relaunch / Restart and the device tools.
    @Published private(set) var lastLaunch: LaunchTarget?
    /// Web: the dev server's URL once it prints one.
    @Published private(set) var webURL: URL?
    /// True while a web dev server runs (Stop signals its whole process tree).
    private var isWebSession = false
    private var openBrowserOnReady = false

    /// Set from the log window: new runs append to the log instead of clearing it.
    /// Turned off again when the log window closes.
    @Published var preserveLog = false

    func run(project: XcodeProject, scheme: String?, simulator: Simulator, options: RunOptions) {
        let description = "\(project.displayName) · \(scheme ?? project.kindLabel) → \(simulator.name) (\(simulator.runtimeName))"
        start(description: description, resetLog: true) { session in
            try await session.perform(project: project, scheme: scheme, simulator: simulator, options: options)
        }
    }

    /// Runs `work` as this session's job: one at a time, with the log, phases and Stop.
    /// While an app is live (streaming), it's stopped first.
    private func start(description: String, resetLog: Bool, work: @escaping (RunSession) async throws -> Void) {
        if phase == .streaming {
            let previous = runTask
            stop()
            Task { [weak self] in
                await previous?.value
                self?.start(description: description, resetLog: resetLog, work: work)
            }
            return
        }
        guard !isRunning else { return }
        if resetLog && !preserveLog {
            beginLog()
        } else if resetLog {
            // Preserve Log: keep the previous output, start a new run below a divider.
            reopenLog()
            warningCount = 0
            errorCount = 0
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            append("")
            append("━━━━━━━━ New run · \(time) ━━━━━━━━")
        } else {
            reopenLog()
            append("")
        }
        runDescription = description
        startedAt = Date()
        finishedAt = nil
        phase = .building

        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushPending() }
        }
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self.append("■ Stopped")
                    self.phase = .cancelled
                } else {
                    self.append("✗ \(error.localizedDescription)")
                    self.phase = .failed(error.localizedDescription)
                }
            }
            self.isFlutterSession = false
            self.isWebSession = false
            self.webURL = nil
            self.statusDetail = ""
            self.finish()
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
        } else if isWebSession, let pid = process?.processIdentifier, pid > 0 {
            // sh → npm → node…: signal the whole tree so the server really stops and frees its port.
            ProcessTree.terminate(pid)
        } else {
            process?.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { process?.terminate() }
        }
    }

    /// App is quitting: stop a running dev server right away.
    func terminateWebServerNow() {
        guard isWebSession, let pid = currentProcess?.processIdentifier, pid > 0 else { return }
        ProcessTree.terminateNow(pid)
    }

    // MARK: - Web dev server

    func runWeb(project: XcodeProject, command: String, options: RunOptions) {
        start(description: "\(project.displayName) · \(command)", resetLog: true) { session in
            try await session.runWebServer(project: project, command: command, options: options)
        }
    }

    private func runWebServer(project: XcodeProject, command: String, options: RunOptions) async throws {
        append("▶ \(command)")
        append("  \(project.directory.path)")
        isWebSession = true
        webURL = nil
        openBrowserOnReady = options.openBrowserWhenReady
        phase = .streaming
        statusDetail = "Starting dev server…"

        var environment = options.environmentPairs
        environment["BROWSER"] = "none"      // we open the browser ourselves (Open, or "open when ready")
        environment["FORCE_COLOR"] = "0"     // plain output in the log window
        let status = await stream("/bin/sh", ["-c", command], in: project.directory, environment: environment,
                                  display: command, showArguments: false)
        isWebSession = false
        webURL = nil
        if Task.isCancelled { throw CancellationError() }
        if status == 0 {
            append("■ Dev server exited")
            phase = .cancelled
        } else {
            throw RunError.toolMissing("The dev server exited with status \(status)."
                                       + (firstError.map { " \($0)" } ?? " See the log for details."))
        }
    }

    /// Dismisses a failed run's message in the popup (the log keeps the details).
    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    /// Empties the log window's view of this session (the log file is kept).
    func clearLog() {
        flushPending()
        logLines = []
        logRevision += 1
    }

    // MARK: - Flutter keys

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

    /// Sends one of `flutter run`'s key commands (v = DevTools, i = inspector, P = performance overlay…).
    func sendFlutterKey(_ key: String, label: String) {
        guard canHotReload else { return }
        append("⌨ \(label)")
        currentProcess?.send(key)
    }

    // MARK: - Relaunch (no rebuild)

    var canRelaunch: Bool {
        guard lastLaunch != nil, !isFlutterSession else { return false }
        return phase == .streaming || !isRunning
    }

    /// Launches the last-built app again without building (Xcode) or restarts it (Android).
    func relaunch() {
        guard let target = lastLaunch, canRelaunch else { return }
        start(description: runDescription, resetLog: false) { session in
            session.append("⟲ Relaunching \(target.appName) on \(target.destinationName)")
            switch target.kind {
            case .simulator, .device:
                try await session.launchApple(target)
            case .androidEmulator, .androidDevice:
                try await session.launchAndroid(target)
            }
        }
    }

    // MARK: - Tool jobs (clean, pub get, tests…)

    /// Streams a long command (e.g. `flutter clean`) into the log as this session's job.
    func runTool(_ title: String, executable: String, arguments: [String], in directory: URL,
                 environment: [String: String] = [:], display: String, showArguments: Bool = true, done: String) {
        start(description: title, resetLog: false) { session in
            session.append("▶ \(title)")
            session.phase = .building
            let status = await session.stream(executable, arguments, in: directory, environment: environment,
                                              display: display, showArguments: showArguments)
            try Task.checkCancellation()
            guard status == 0 else {
                throw RunError.buildFailed(status: status, firstError: session.firstError)
            }
            session.append("✓ \(done)")
            session.phase = .finished(done)
        }
    }

    /// Xcode build / test / clean for the scheme, without launching anything.
    func runXcodeTool(_ action: String, project: XcodeProject, scheme: String, destination: Simulator,
                      options: RunOptions) {
        let title = "\(action.capitalized) \(scheme)"
        start(description: title, resetLog: true) { session in
            session.append("▶ \(title) → \(destination.name)")
            let base = await session.xcodeBaseArguments(project: project, scheme: scheme, destination: destination,
                                                        options: options)
            var arguments = base.arguments
            if action != "clean" { arguments += ["-skipPackagePluginValidation", "-skipMacroValidation"] }
            if destination.kind == .device, action != "clean" { arguments += ["-allowProvisioningUpdates"] }
            session.phase = .building
            let status = await session.stream(Shell.xcrunPath, arguments + [action], in: project.directory,
                                              display: "xcrun")
            try Task.checkCancellation()
            guard status == 0 else {
                throw RunError.buildFailed(status: status, firstError: session.firstError)
            }
            let done = action == "test" ? "Tests passed" : (action == "clean" ? "Cleaned" : "Build succeeded")
            session.append("✓ \(done)")
            session.phase = .finished(done)
        }
    }

    /// A short command that doesn't interrupt a running app (appearance, permissions, push…).
    /// Its output goes to the log; returns the output, or throws with the error.
    @discardableResult
    func quick(_ title: String, executable: String = Shell.xcrunPath, arguments: [String],
               environment: [String: String] = [:], display: String = "xcrun") async throws -> String {
        reopenLogIfIdle()
        append("▶ \(title)")
        append("$ \(display) " + arguments.map(Self.shellQuote).joined(separator: " "))
        let result = try await Shell.run(executable, arguments, environment: environment)
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        for line in output.split(whereSeparator: \.isNewline) { append(String(line)) }
        guard result.succeeded else {
            throw ShellError.failed(command: title, status: result.status, output: output)
        }
        return output
    }

    // MARK: - Pipeline

    private func perform(project: XcodeProject, scheme: String?, simulator: Simulator, options: RunOptions) async throws {
        append("▶ \(scheme ?? project.kindLabel) on \(simulator.name) — \(simulator.runtimeName)")
        append("  \(project.url.path)")
        switch project.kind {
        case .workspace, .project:
            guard let scheme else { throw RunError.missingScheme }
            try await runXcode(project: project, scheme: scheme, simulator: simulator, options: options)
        case .flutter:
            try await runFlutter(project: project, destination: simulator, options: options)
        case .android:
            try await runAndroid(project: project, destination: simulator, options: options)
        case .web:
            throw RunError.toolMissing("Web projects start with their dev server command.")
        }
    }

    // MARK: Xcode

    /// xcodebuild arguments for the scheme, with the configuration from the options or the scheme's Run action.
    private func xcodeBaseArguments(project: XcodeProject, scheme: String, destination: Simulator,
                                    options: RunOptions) async -> (arguments: [String], target: String?) {
        let container = project.url
        let launch = await Task.detached { SchemeLaunchInfo.load(scheme: scheme, near: container) }.value
        let override = options.configuration.trimmingCharacters(in: .whitespaces)
        let configuration = override.isEmpty ? (launch.configuration ?? "Debug") : override
        let source = !override.isEmpty ? " (from Run Options)"
            : (launch.configuration == nil ? " (scheme file not found, using default)" : "")
        append("Scheme: \(scheme) · Configuration: \(configuration)" + source
               + (launch.target.map { " · Runs: \($0)" } ?? ""))
        return ([
            "xcodebuild", project.containerFlag, project.url.path,
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", "id=\(destination.udid)",
        ], launch.target)
    }

    private func runXcode(project: XcodeProject, scheme: String, simulator: Simulator, options: RunOptions) async throws {
        let udid = simulator.udid
        let isDevice = simulator.kind == .device
        // Boot the simulator in parallel with the build to save time (not needed for real devices).
        let bootTask: Task<ShellResult, Error>? = isDevice ? nil : Task.detached { () -> ShellResult in
            try await Shell.run(Shell.xcrunPath, ["simctl", "bootstatus", udid, "-b"])
        }

        let base = await xcodeBaseArguments(project: project, scheme: scheme, destination: simulator, options: options)
        var buildArguments = base.arguments + ["-skipPackagePluginValidation", "-skipMacroValidation"]
        if isDevice {
            // Let Xcode create/refresh provisioning profiles (automatic signing).
            buildArguments += ["-allowProvisioningUpdates"]
        }

        phase = .building
        let status = await stream(Shell.xcrunPath, buildArguments + ["build"], in: project.directory, display: "xcrun")
        try Task.checkCancellation()
        guard status == 0 else { throw RunError.buildFailed(status: status, firstError: firstError) }

        phase = .preparing
        let product = try await locateProduct(base: base.arguments,
                                              preferredTargets: [base.target, scheme].compactMap { $0 },
                                              in: project.directory)
        append("App: \(product.appURL.path)")
        append("Bundle ID: \(product.bundleIdentifier)")
        KnownAppIDs.set(product.bundleIdentifier, for: projectID)
        try Task.checkCancellation()

        let target = LaunchTarget(
            kind: simulator.kind, udid: udid, serial: nil,
            appID: product.bundleIdentifier,
            appName: product.appURL.deletingPathExtension().lastPathComponent,
            destinationName: simulator.name,
            arguments: options.launchArgumentList,
            environment: options.environmentPairs
        )

        if isDevice {
            phase = .installing
            try await logged(["devicectl", "device", "install", "app", "--device", udid, product.appURL.path])
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
        }
        try Task.checkCancellation()
        try await launchApple(target)
    }

    /// Launches an installed Apple app with its console attached, passing launch arguments and environment.
    private func launchApple(_ target: LaunchTarget) async throws {
        lastLaunch = target
        phase = .launching
        if !target.arguments.isEmpty {
            append("Launch arguments: " + target.arguments.map(Self.shellQuote).joined(separator: " "))
        }
        if !target.environment.isEmpty {
            append("Environment: " + target.environment.keys.sorted().joined(separator: ", "))
        }

        if target.kind == .device {
            // Like Xcode: unbuffered stdout so `print` arrives right away (it's fully buffered without a
            // terminal), and OS_ACTIVITY_DT_MODE so NSLog / os_log / Logger are mirrored to stderr,
            // which is what `devicectl --console` forwards. Your own variables win.
            let environment = Self.consoleEnvironment.merging(target.environment) { _, custom in custom }
            var environmentFlag: [String] = []
            if let json = try? JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys]),
               let text = String(data: json, encoding: .utf8) {
                environmentFlag = ["--environment-variables", text]
            }
            try await launchWithConsole(
                ["devicectl", "device", "process", "launch", "--console", "--terminate-existing",
                 "--device", target.udid] + environmentFlag + [target.appID] + target.arguments,
                // Older devicectl without --console / --environment-variables: plain launch, no live logs.
                fallback: ["devicectl", "device", "process", "launch", "--device", target.udid,
                           "--terminate-existing", target.appID] + target.arguments,
                environment: [:],
                appName: target.appName,
                destination: target.destinationName,
                stopNote: "Stop detaches from the app; it keeps running on the device."
            )
        } else {
            // --console-pty streams the app's stdout/stderr (print, NSLog) and passes Stop (SIGINT) to the app.
            // SIMCTL_CHILD_ variables reach the app's environment; OS_ACTIVITY_DT_MODE also mirrors
            // os_log / Logger output, like Xcode's console.
            var environment: [String: String] = [:]
            for (key, value) in Self.consoleEnvironment.merging(target.environment, uniquingKeysWith: { _, custom in custom }) {
                environment["SIMCTL_CHILD_" + key] = value
            }
            try await launchWithConsole(
                ["simctl", "launch", "--console-pty", "--terminate-running-process", target.udid, target.appID]
                    + target.arguments,
                fallback: ["simctl", "launch", "--terminate-running-process", target.udid, target.appID]
                    + target.arguments,
                environment: environment,
                appName: target.appName,
                destination: target.destinationName,
                stopNote: "Stop quits the app."
            )
        }
    }

    /// What Xcode sets so an app's console output shows up live: unbuffered stdio for `print`,
    /// and os_log / Logger / NSLog mirrored to stderr.
    private static let consoleEnvironment = [
        "NSUnbufferedIO": "YES",
        "OS_ACTIVITY_DT_MODE": "enable",
    ]

    /// Launches with the app's console attached and streams its output until the app exits or Stop.
    /// If this Xcode's tool doesn't know the console option, launches without it (no live logs).
    private func launchWithConsole(_ arguments: [String], fallback: [String], environment: [String: String],
                                   appName: String, destination: String, stopNote: String) async throws {
        phase = .streaming
        statusDetail = "Live logs · \(stopNote)"
        append("✓ Launching \(appName) on \(destination); its output follows. \(stopNote)")
        let mark = logLines.count
        let status = await stream(Shell.xcrunPath, arguments, in: FileManager.default.temporaryDirectory,
                                  environment: environment, display: "xcrun")
        if Task.isCancelled { throw CancellationError() }

        let output = logLines.suffix(max(0, logLines.count - mark)).joined(separator: "\n").lowercased()
        let unsupported = ["unknown option", "unrecognized option", "unexpected argument", "unknown argument"]
        if status != 0, unsupported.contains(where: output.contains) {
            append("This Xcode can't attach to the app's console, so live logs aren't available. Launching without them.")
            phase = .launching
            try await logged(fallback, environment: environment)
            append("✓ Launched \(appName) on \(destination)")
            phase = .succeeded
            return
        }
        if status == 0 {
            append("■ \(appName) exited")
            phase = .cancelled
        } else {
            append("■ \(appName) exited (status \(status))")
            phase = .failed("\(appName) exited with status \(status)")
        }
        statusDetail = ""
    }

    // MARK: Flutter

    private func runFlutter(project: XcodeProject, destination: Simulator, options: RunOptions) async throws {
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
            try await applyReversePorts(options.ports, serial: deviceID)
        }
        try Task.checkCancellation()

        var arguments = ["run", "-d", deviceID, "--\(options.flutterMode.rawValue)"]
        let flavor = options.flutterFlavor.trimmingCharacters(in: .whitespaces)
        if !flavor.isEmpty { arguments += ["--flavor", flavor] }
        let target = options.flutterTarget.trimmingCharacters(in: .whitespaces)
        if !target.isEmpty { arguments += ["-t", target] }
        arguments += options.dartDefinePairs.map { "--dart-define=\($0)" }
        if options.flutterMode != .debug, destination.kind == .simulator {
            append("Note: Flutter only supports debug mode on iOS simulators; use a device for \(options.flutterMode.title).")
        }

        phase = .building
        isFlutterSession = true
        let status = await stream(flutter, arguments, in: project.directory, display: "flutter", interactive: true)
        isFlutterSession = false
        try Task.checkCancellation()
        guard status == 0 else { throw RunError.buildFailed(status: status, firstError: firstError) }
        append("Flutter session ended")
        phase = .cancelled
    }

    // MARK: Android

    private func runAndroid(project: XcodeProject, destination: Simulator, options: RunOptions) async throws {
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

        let task = ":\(module):install\(options.gradleVariant)"
        phase = .building
        let status = await stream("/bin/sh", [gradlew, task, "--console=plain"],
                                  in: project.url, environment: ["ANDROID_SERIAL": serial],
                                  display: "./gradlew \(task) --console=plain", showArguments: false)
        try Task.checkCancellation()
        guard status == 0 else { throw RunError.buildFailed(status: status, firstError: firstError) }

        try await applyReversePorts(options.ports, serial: serial)

        let applicationID = try Self.androidApplicationID(project: project, module: module,
                                                          variant: options.androidVariant)
        append("Application ID: \(applicationID)")
        KnownAppIDs.set(applicationID, for: projectID)
        try await launchAndroid(LaunchTarget(
            kind: destination.kind, udid: destination.udid, serial: serial, appID: applicationID,
            appName: applicationID, destinationName: destination.name
        ))
    }

    /// `adb reverse tcp:N tcp:N` so the app on the device can reach servers on this Mac.
    private func applyReversePorts(_ ports: [Int], serial: String) async throws {
        guard !ports.isEmpty, let adb = AndroidSDK.adb else { return }
        for port in ports {
            try await logged(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"], executable: adb, display: "adb")
        }
    }

    /// (Re)starts an installed Android app and streams its logcat until Stop.
    private func launchAndroid(_ target: LaunchTarget) async throws {
        guard let adb = AndroidSDK.adb, let serial = target.serial else { throw AndroidError.sdkNotFound }
        lastLaunch = target
        phase = .launching
        _ = try? await Shell.run(adb, ["-s", serial, "shell", "am", "force-stop", target.appID])
        try await logged(["-s", serial, "shell", "monkey", "-p", target.appID,
                          "-c", "android.intent.category.LAUNCHER", "1"], executable: adb, display: "adb")
        append("✓ Launched \(target.appID) on \(target.destinationName)")

        // Live logs: logcat filtered to the app's process.
        var pid: String?
        for _ in 0..<10 where pid == nil {
            try await Task.sleep(nanoseconds: 300_000_000)
            let result = try? await Shell.run(adb, ["-s", serial, "shell", "pidof", "-s", target.appID])
            let value = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty, Int(value) != nil { pid = value }
        }
        guard let pid else {
            append("Couldn't find the app's process, so live logs aren't shown.")
            phase = .succeeded
            return
        }

        phase = .streaming
        statusDetail = "Live logs · Stop quits the app."
        append("Live logs (logcat, pid \(pid)). Stop quits the app.")
        _ = await stream(adb, ["-s", serial, "logcat", "-v", "time", "--pid=\(pid)"],
                         in: FileManager.default.temporaryDirectory, display: "adb")
        if Task.isCancelled {
            _ = try? await Shell.run(adb, ["-s", serial, "shell", "am", "force-stop", target.appID])
            throw CancellationError()
        }
        append("■ Log stream ended")
        statusDetail = ""
        phase = .cancelled
    }

    /// Reads the applicationId from the build output (AGP 4.1+), falling back to the module's build script.
    nonisolated static func androidApplicationID(project: XcodeProject, module: String, variant: String = "") throws -> String {
        let metadata = project.url.appendingPathComponent("\(module)/build/outputs/apk/\(apkOutputPath(variant))/output-metadata.json")
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

    /// "" → "debug"; "freeDebug" → "free/debug"; "freeStagingRelease" → "freeStaging/release".
    nonisolated static func apkOutputPath(_ variant: String) -> String {
        let trimmed = variant.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "debug" }
        // The build type is the last capitalized word.
        guard let split = trimmed.lastIndex(where: { $0.isUppercase }), split != trimmed.startIndex else {
            return trimmed.lowercased()
        }
        let flavor = trimmed[..<split]
        let buildType = trimmed[split...].lowercased()
        return "\(flavor)/\(buildType)"
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
    private func logged(_ arguments: [String], executable: String = Shell.xcrunPath, display: String = "xcrun",
                        environment: [String: String] = [:]) async throws -> ShellResult {
        append("$ \(display) " + arguments.map(Self.shellQuote).joined(separator: " "))
        let result = try await Shell.run(executable, arguments, environment: environment)
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

    private func locateProduct(base: [String], preferredTargets: [String], in directory: URL) async throws -> BuiltProduct {
        append("Reading build settings…")
        let result = try await Shell.run(Shell.xcrunPath, base + ["-showBuildSettings", "-json"], currentDirectory: directory)
        let output = result.stdout
        guard let start = output.range(of: "[\n")?.lowerBound ?? output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"), start < end else {
            throw RunError.productNotFound(detail: result.stderr)
        }
        let entries = try JSONDecoder().decode([SettingsEntry].self, from: Data(output[start...end].utf8))

        // Prefer the target the scheme launches, then one named like the scheme;
        // skip non-app products (frameworks, tests…).
        func rank(_ entry: SettingsEntry) -> Int {
            entry.target.flatMap { preferredTargets.firstIndex(of: $0) } ?? preferredTargets.count
        }
        let apps = entries
            .filter { $0.buildSettings["WRAPPER_EXTENSION"] == "app" }
            .sorted { rank($0) < rank($1) }

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

    /// Keeps the current log and appends to its file (for tools and relaunches).
    private func reopenLog() {
        firstError = nil
        statusDetail = ""
        guard logHandle == nil else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()
    }

    /// Quick tools write to the log file too, even when nothing is running.
    private func reopenLogIfIdle() {
        if logHandle == nil {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            logHandle = try? FileHandle(forWritingTo: logURL)
            _ = try? logHandle?.seekToEnd()
        }
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
        var line = raw.replacingOccurrences(of: "\r", with: "")
        // Colour/cursor escape codes (Vite, Next, Gradle…) would show up as junk in the log window.
        if line.contains("\u{1B}") {
            line = line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        }
        if isWebSession, webURL == nil, let url = WebProject.url(in: line) {
            webURL = url
            statusDetail = "Dev server · \(url.absoluteString)"
            if openBrowserOnReady { NSWorkspace.shared.open(url) }
        }
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

/// What a scheme's Run (Launch) action uses, read from its `.xcscheme` file.
struct SchemeLaunchInfo {
    /// e.g. "Debug" or "Debug-Staging".
    var configuration: String?
    /// Target the Run action launches (`BlueprintName`).
    var target: String?

    /// Looks for `<scheme>.xcscheme` in the project/workspace's shared and user scheme folders,
    /// then anywhere under the project's folder (skipping Pods and build output).
    static func load(scheme: String, near container: URL) -> SchemeLaunchInfo {
        guard let file = schemeFile(named: scheme, near: container),
              let document = try? XMLDocument(contentsOf: file, options: []) else {
            return SchemeLaunchInfo()
        }
        func attribute(_ xpath: String) -> String? {
            let value = (try? document.nodes(forXPath: xpath))?.first?.stringValue?
                .trimmingCharacters(in: .whitespaces)
            return value?.isEmpty == false ? value : nil
        }
        return SchemeLaunchInfo(
            configuration: attribute("/Scheme/LaunchAction/@buildConfiguration"),
            target: attribute("/Scheme/LaunchAction/BuildableProductRunnable/BuildableReference/@BlueprintName")
                ?? attribute("/Scheme/LaunchAction/MacroExpansion/BuildableReference/@BlueprintName")
        )
    }

    private static func schemeFile(named scheme: String, near container: URL) -> URL? {
        let fm = FileManager.default
        let name = "\(scheme).xcscheme"

        // 1. The container itself: shared schemes first, then the user's own.
        var candidates = [container.appendingPathComponent("xcshareddata/xcschemes/\(name)")]
        let userData = container.appendingPathComponent("xcuserdata")
        if let users = try? fm.contentsOfDirectory(at: userData, includingPropertiesForKeys: nil) {
            candidates += users.map { $0.appendingPathComponent("xcschemes/\(name)") }
        }
        if let hit = candidates.first(where: { fm.fileExists(atPath: $0.path) }) { return hit }

        // 2. Workspaces: the scheme usually lives in one of the referenced .xcodeproj bundles.
        let root = container.deletingLastPathComponent()
        let skipped: Set<String> = ["Pods", "DerivedData", "build", ".build", "node_modules", ".git", "Carthage"]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { return nil }
        var userMatch: URL?
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) || walker.level > 6 {
                walker.skipDescendants()
                continue
            }
            guard url.lastPathComponent == name else { continue }
            if url.path.contains("/xcshareddata/") { return url }
            userMatch = userMatch ?? url
        }
        return userMatch
    }
}

/// An installed app the session launched, so it can be relaunched or restarted without rebuilding.
struct LaunchTarget: Equatable {
    let kind: Simulator.Kind
    let udid: String
    /// Android: adb serial.
    let serial: String?
    /// Bundle identifier (Apple) or application ID (Android).
    let appID: String
    let appName: String
    let destinationName: String
    var arguments: [String] = []
    var environment: [String: String] = [:]
}
