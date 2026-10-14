import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ⋯ menu next to Run

/// Actions that depend on the project type and on whether the app is running:
/// Flutter key commands and pub tools, Xcode build/test/clean and Simulator controls,
/// Android restart/clear data/dark mode/port forwarding. Ends with Run Options….
struct ProjectToolsMenu: View {
    let project: XcodeProject
    let destination: Simulator?
    let openOptions: () -> Void
    /// Shows a result message under the run buttons (text, isError).
    let report: (String, Bool) -> Void

    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var runner: BuildRunner

    private var session: RunSession? { runner.session(for: project.id) }
    private var phase: RunPhase { session?.phase ?? .idle }
    private var isRunning: Bool { session?.isRunning ?? false }
    private var options: RunOptions { projects.runOptions(for: project) }
    private var scheme: String? { projects.selectedScheme(for: project) }

    var body: some View {
        Menu {
            switch project.kind {
            case .flutter: flutterItems
            case .workspace, .project: xcodeItems
            case .android: androidItems
            case .web: webItems
            }
            Divider()
            Button("Run Options…", action: openOptions)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .controlSize(.large)
        .fixedSize()
        .help("More \(project.kindLabel) actions and Run Options")
    }

    // MARK: Flutter

    @ViewBuilder
    private var flutterItems: some View {
        if phase == .attached, let session {
            Section("Running App") {
                Button("Open DevTools") { session.sendFlutterKey("v", label: "Open DevTools") }
                Button("Toggle Widget Inspector") { session.sendFlutterKey("i", label: "Toggle widget inspector") }
                Button("Toggle Performance Overlay") { session.sendFlutterKey("P", label: "Toggle performance overlay") }
                Button("Toggle Debug Paint") { session.sendFlutterKey("p", label: "Toggle debug paint") }
                Button("Toggle iOS / Android Look") { session.sendFlutterKey("o", label: "Toggle platform look") }
                Divider()
                Button("Detach (Keep App Running)") { session.sendFlutterKey("d", label: "Detach") }
            }
        }

        Picker("Run Mode", selection: binding(\.flutterMode)) {
            ForEach(FlutterMode.allCases) { Text($0.title).tag($0) }
        }

        Section("Project") {
            Button("flutter clean") { flutterTool(["clean"], done: "flutter clean finished") }
            Button("flutter pub get") { flutterTool(["pub", "get"], done: "Packages fetched") }
            Button("flutter pub upgrade") { flutterTool(["pub", "upgrade"], done: "Packages upgraded") }
        }
        .disabled(isRunning)
    }

    private func flutterTool(_ arguments: [String], done: String) {
        guard let flutter = Shell.which("flutter") else {
            report("Flutter SDK not found on your PATH.", true)
            return
        }
        runner.session(ensuring: project).runTool(
            "flutter " + arguments.joined(separator: " "), executable: flutter, arguments: arguments,
            in: project.directory, display: "flutter", done: done
        )
    }

    // MARK: Xcode

    private var appleAppID: String? { session?.lastLaunch?.appID ?? KnownAppIDs.get(project.id) }

    @ViewBuilder
    private var xcodeItems: some View {
        if session?.canRelaunch == true, let target = session?.lastLaunch {
            Button("Relaunch Without Building") { session?.relaunch() }
                .help("Launch \(target.appName) again on \(target.destinationName)")
            Divider()
        }

        Section("Build") {
            Button("Build Only") { xcodeTool("build") }
            Button("Run Tests") { xcodeTool("test") }
            Button("Clean Build Folder") { xcodeTool("clean") }
        }
        .disabled(isRunning || scheme == nil || destination == nil)

        Section("App") {
            Button(appleAppID == nil ? "Uninstall App (run once first)" : "Uninstall App") { uninstallApple() }
                .disabled(appleAppID == nil || destination == nil || isRunning)
        }

        if let destination, destination.kind == .simulator {
            Section(destination.isBooted ? "Simulator" : "Simulator (boot it to use these)") {
                Menu("Appearance") {
                    Button("Dark") { simctl("Dark appearance", ["ui", destination.udid, "appearance", "dark"]) }
                    Button("Light") { simctl("Light appearance", ["ui", destination.udid, "appearance", "light"]) }
                }
                Menu("Permissions") {
                    Button("Grant All") { privacy("grant", destination) }
                    Button("Reset All") { privacy("reset", destination) }
                }
                .disabled(appleAppID == nil)
                Menu("Location") { locationItems(destination) }
                Menu("Push Notification") {
                    Button("Send Test Notification") { sendTestPush(destination) }
                    Button("Send from File…") { sendPushFromFile(destination) }
                }
                .disabled(appleAppID == nil)
            }
            .disabled(!destination.isBooted)
        }
    }

    private struct Place: Hashable {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    private static let locations: [Place] = [
        Place(name: "Apple Park, Cupertino", latitude: 37.3349, longitude: -122.0090),
        Place(name: "San Francisco", latitude: 37.7749, longitude: -122.4194),
        Place(name: "New York", latitude: 40.7128, longitude: -74.0060),
        Place(name: "London", latitude: 51.5074, longitude: -0.1278),
        Place(name: "Tokyo", latitude: 35.6762, longitude: 139.6503),
        Place(name: "Dhaka", latitude: 23.8103, longitude: 90.4125),
        Place(name: "Sydney", latitude: -33.8688, longitude: 151.2093),
    ]

    @ViewBuilder
    private func locationItems(_ destination: Simulator) -> some View {
        ForEach(Self.locations, id: \.self) { place in
            Button(place.name) { setLocation(place.name, place.latitude, place.longitude, destination) }
        }
        Divider()
        if let custom = options.customCoordinate {
            Button(String(format: "Custom (%.4f, %.4f)", custom.0, custom.1)) {
                setLocation("Custom location", custom.0, custom.1, destination)
            }
        } else {
            Button("Custom… (set it in Run Options)", action: openOptions)
        }
        Button("Clear Location") {
            simctl("Clear location", ["location", destination.udid, "clear"], success: "Location cleared.")
        }
    }

    private func xcodeTool(_ action: String) {
        guard let scheme, let destination else { return }
        runner.session(ensuring: project).runXcodeTool(action, project: project, scheme: scheme,
                                                       destination: destination, options: options)
    }

    private func uninstallApple() {
        guard let appID = appleAppID, let destination else { return }
        if destination.kind == .device {
            quick("Uninstall \(appID)", ["devicectl", "device", "uninstall", "app", "--device", destination.udid, appID],
                  success: "Uninstalled \(appID) from \(destination.name).")
        } else {
            simctl("Uninstall \(appID)", ["uninstall", destination.udid, appID],
                   success: "Uninstalled \(appID) from \(destination.name).")
        }
    }

    private func privacy(_ action: String, _ destination: Simulator) {
        guard let appID = appleAppID else { return }
        simctl("\(action.capitalized) all permissions", ["privacy", destination.udid, action, "all", appID],
               success: action == "grant" ? "Granted all permissions to \(appID)." : "Reset permissions for \(appID).")
    }

    private func setLocation(_ name: String, _ latitude: Double, _ longitude: Double, _ destination: Simulator) {
        simctl("Set location: \(name)", ["location", destination.udid, "set", "\(latitude),\(longitude)"],
               success: "Location set to \(name).")
    }

    private func sendTestPush(_ destination: Simulator) {
        guard let appID = appleAppID else { return }
        let payload: [String: Any] = [
            "aps": [
                "alert": ["title": "RunXcodeApp", "body": "Test notification"],
                "sound": "default",
                "badge": 1,
            ],
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runxcodeapp-push.json")
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              (try? data.write(to: url)) != nil else {
            report("Couldn't write the notification payload.", true)
            return
        }
        simctl("Send test notification", ["push", destination.udid, appID, url.path],
               success: "Notification sent to \(appID).")
    }

    private func sendPushFromFile(_ destination: Simulator) {
        guard let appID = appleAppID else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Push Payload"
        panel.message = "A .json or .apns file with an \"aps\" dictionary."
        panel.allowedContentTypes = [UTType.json] + [UTType(filenameExtension: "apns")].compactMap { $0 }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        simctl("Send notification from \(url.lastPathComponent)", ["push", destination.udid, appID, url.path],
               success: "Notification sent to \(appID).")
    }

    private func simctl(_ title: String, _ arguments: [String], success: String? = nil) {
        quick(title, ["simctl"] + arguments, success: success ?? "\(title): done.")
    }

    // MARK: Android

    private var androidAppID: String? {
        if let id = session?.lastLaunch?.appID { return id }
        if let id = KnownAppIDs.get(project.id) { return id }
        return try? RunSession.androidApplicationID(project: project, module: project.androidModule ?? "app",
                                                    variant: options.androidVariant)
    }

    private var serial: String? { destination?.serial }

    @ViewBuilder
    private var androidItems: some View {
        if session?.canRelaunch == true, session?.lastLaunch != nil {
            Button("Restart App") { session?.relaunch() }
        }
        Button("Clear App Data") {
            guard let appID = androidAppID, let serial, let adb = AndroidSDK.adb else { return }
            quick("Clear data for \(appID)", ["-s", serial, "shell", "pm", "clear", appID], executable: adb,
                  display: "adb", success: "Cleared data for \(appID).")
        }
        .disabled(androidAppID == nil || serial == nil)
        Divider()

        Section(serial == nil ? "Device (start it to use these)" : "Device") {
            Menu("Dark Mode") {
                Button("On") { uimode("yes") }
                Button("Off") { uimode("no") }
            }
            let ports = options.ports
            Button(ports.isEmpty ? "Port Forwarding… (set ports in Run Options)"
                                 : "Apply Port Forwarding (\(ports.map(String.init).joined(separator: ", ")))") {
                if ports.isEmpty { openOptions() } else { reversePorts(ports) }
            }
        }
        .disabled(serial == nil)

        Section("Project") {
            Button("Gradle Clean") { gradleClean() }
                .disabled(isRunning)
            Button("Uninstall App") {
                guard let appID = androidAppID, let serial, let adb = AndroidSDK.adb else { return }
                quick("Uninstall \(appID)", ["-s", serial, "uninstall", appID], executable: adb, display: "adb",
                      success: "Uninstalled \(appID).")
            }
            .disabled(androidAppID == nil || serial == nil || isRunning)
        }
    }

    private func uimode(_ value: String) {
        guard let serial, let adb = AndroidSDK.adb else { return }
        quick("Dark mode \(value == "yes" ? "on" : "off")", ["-s", serial, "shell", "cmd", "uimode", "night", value],
              executable: adb, display: "adb", success: "Dark mode \(value == "yes" ? "on" : "off").")
    }

    private func reversePorts(_ ports: [Int]) {
        guard let serial, let adb = AndroidSDK.adb else { return }
        let session = runner.session(ensuring: project)
        Task {
            do {
                for port in ports {
                    try await session.quick("adb reverse \(port)", executable: adb,
                                            arguments: ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"],
                                            display: "adb")
                }
                report("Forwarding \(ports.map(String.init).joined(separator: ", ")) from the device to this Mac.", false)
            } catch {
                report(error.localizedDescription, true)
            }
        }
    }

    private func gradleClean() {
        let gradlew = project.url.appendingPathComponent("gradlew").path
        guard FileManager.default.fileExists(atPath: gradlew) else {
            report("No gradlew in \(project.name).", true)
            return
        }
        runner.session(ensuring: project).runTool(
            "Gradle clean", executable: "/bin/sh", arguments: [gradlew, "clean", "--console=plain"],
            in: project.url, display: "./gradlew clean", done: "Gradle clean finished"
        )
    }

    // MARK: Web

    @ViewBuilder
    private var webItems: some View {
        if let url = session?.webURL {
            Section("Dev Server") {
                Button("Open \(url.absoluteString)") { NSWorkspace.shared.open(url) }
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    report("Copied \(url.absoluteString)", false)
                }
            }
        }

        let directory = project.directory
        let manager = WebProject.manager(in: directory)
        let scripts = WebProject.scripts(in: directory)
        Section("Project") {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.json").path) {
                Button("Install Dependencies (\(manager.install))") {
                    shellTool(manager.install, done: "Dependencies installed")
                }
            }
            if !scripts.isEmpty {
                Menu("Run Script") {
                    ForEach(scripts, id: \.name) { script in
                        Button("\(script.name)  —  \(script.command)") {
                            shellTool(manager.run(script.name), done: "\(script.name) finished")
                        }
                    }
                }
            }
        }
        .disabled(isRunning)
    }

    /// Runs a shell command in the project folder as a job (output in the log).
    private func shellTool(_ command: String, done: String) {
        runner.session(ensuring: project).runTool(
            command, executable: "/bin/sh", arguments: ["-c", command], in: project.directory,
            environment: ["FORCE_COLOR": "0", "BROWSER": "none"], display: command, showArguments: false, done: done
        )
    }

    // MARK: Helpers

    private func quick(_ title: String, _ arguments: [String], executable: String = Shell.xcrunPath,
                       display: String = "xcrun", success: String) {
        let session = runner.session(ensuring: project)
        Task {
            do {
                try await session.quick(title, executable: executable, arguments: arguments, display: display)
                report(success, false)
            } catch {
                report(error.localizedDescription, true)
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<RunOptions, T>) -> Binding<T> {
        Binding(
            get: { projects.runOptions(for: project)[keyPath: keyPath] },
            set: { value in projects.updateRunOptions(for: project) { $0[keyPath: keyPath] = value } }
        )
    }
}

// MARK: - Run Options page

/// Per-project settings for Run: Flutter mode/flavor/entry file/dart-defines, Xcode configuration,
/// launch arguments, environment and custom location, Android variant and port forwarding.
struct RunOptionsPage: View {
    let close: () -> Void
    @EnvironmentObject private var projects: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let project = projects.selectedProject {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch project.kind {
                        case .flutter: flutterFields(project)
                        case .workspace, .project: xcodeFields(project)
                        case .android: androidFields(project)
                        case .web: webFields(project)
                        }
                        HStack {
                            Spacer()
                            Button("Reset to Defaults") {
                                projects.updateRunOptions(for: project) { $0 = RunOptions() }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        Button(action: close) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Run Options").font(.body.weight(.semibold))
                    Text(projects.selectedProject.map { "\($0.name) · \($0.kindLabel)" } ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                DrillChevron(isOpen: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRow()
        .help("Back")
    }

    // MARK: Flutter

    @ViewBuilder
    private func flutterFields(_ project: XcodeProject) -> some View {
        field("Mode", "Profile and Release need a physical device on iOS.") {
            Picker("Mode", selection: binding(project, \.flutterMode)) {
                ForEach(FlutterMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        field("Flavor", "Passed as --flavor. Leave empty for none.") {
            TextField("e.g. staging", text: binding(project, \.flutterFlavor))
                .textFieldStyle(.roundedBorder)
        }
        field("Entry file", "Passed as -t. Leave empty for lib/main.dart.") {
            HStack(spacing: 6) {
                TextField("lib/main.dart", text: binding(project, \.flutterTarget))
                    .textFieldStyle(.roundedBorder)
                let entries = Self.entryFiles(in: project.directory)
                if !entries.isEmpty {
                    Menu {
                        ForEach(entries, id: \.self) { entry in
                            Button(entry) { projects.updateRunOptions(for: project) { $0.flutterTarget = entry } }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Entry files found in lib/")
                }
            }
        }
        field("Dart defines", "One KEY=VALUE per line, passed as --dart-define.") {
            multiline(binding(project, \.dartDefines), placeholder: "API_URL=https://staging.example.com")
        }
        field("Port forwarding (Android)", "Ports for adb reverse before running on Android, e.g. 8080 3000.") {
            TextField("e.g. 8080 3000", text: binding(project, \.reversePorts))
                .textFieldStyle(.roundedBorder)
        }
    }

    /// lib/main*.dart files, for the entry file menu.
    private static func entryFiles(in directory: URL) -> [String] {
        let lib = directory.appendingPathComponent("lib")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? []
        return names.filter { $0.hasPrefix("main") && $0.hasSuffix(".dart") }.sorted().map { "lib/" + $0 }
    }

    // MARK: Xcode

    @ViewBuilder
    private func xcodeFields(_ project: XcodeProject) -> some View {
        field("Configuration", "Leave empty to use the scheme's Run configuration.") {
            HStack(spacing: 6) {
                TextField("Scheme default", text: binding(project, \.configuration))
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button("Scheme default") { projects.updateRunOptions(for: project) { $0.configuration = "" } }
                    Button("Debug") { projects.updateRunOptions(for: project) { $0.configuration = "Debug" } }
                    Button("Release") { projects.updateRunOptions(for: project) { $0.configuration = "Release" } }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        field("Launch arguments", "Passed to the app, like a scheme's Arguments. Use quotes for spaces.") {
            TextField("e.g. -FIRDebugEnabled -AppleLanguages (de)", text: binding(project, \.launchArguments))
                .textFieldStyle(.roundedBorder)
        }
        field("Environment", "One KEY=VALUE per line, set in the app's environment.") {
            multiline(binding(project, \.environment), placeholder: "API_ENV=staging")
        }
        field("Custom location", "Latitude, longitude for ⋯ › Location › Custom (Simulator).") {
            TextField("e.g. 23.8103, 90.4125", text: binding(project, \.customLocation))
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Android

    @ViewBuilder
    private func androidFields(_ project: XcodeProject) -> some View {
        field("Build variant", "Gradle variant to install, e.g. freeDebug or stagingDebug. Leave empty for debug.") {
            TextField("debug", text: binding(project, \.androidVariant))
                .textFieldStyle(.roundedBorder)
        }
        field("Port forwarding", "Ports for adb reverse after install, so the app can reach servers on this Mac.") {
            TextField("e.g. 8080 3000", text: binding(project, \.reversePorts))
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Web

    @ViewBuilder
    private func webFields(_ project: XcodeProject) -> some View {
        let detected = WebProject.defaultCommand(in: project.directory)
        field("Dev server command",
              detected.isEmpty ? "Runs in the project folder with your shell's PATH."
                               : "Leave empty to use the detected command: \(detected)") {
            TextField(detected.isEmpty ? "e.g. npm run dev" : detected, text: binding(project, \.webCommand))
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
        }
        field("Browser", "Opens the first localhost URL the server prints. The Open button works either way.") {
            Toggle("Open in browser when the server is ready", isOn: binding(project, \.openBrowserWhenReady))
        }
        field("Environment", "One KEY=VALUE per line, e.g. PORT=3001.") {
            multiline(binding(project, \.environment), placeholder: "PORT=3001")
        }
    }

    // MARK: Pieces

    private func field<Content: View>(_ title: String, _ caption: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold))
            content()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func multiline(_ text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 64)
                .padding(4)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    private func binding<T>(_ project: XcodeProject, _ keyPath: WritableKeyPath<RunOptions, T>) -> Binding<T> {
        Binding(
            get: { projects.runOptions(for: project)[keyPath: keyPath] },
            set: { value in projects.updateRunOptions(for: project) { $0[keyPath: keyPath] = value } }
        )
    }
}
