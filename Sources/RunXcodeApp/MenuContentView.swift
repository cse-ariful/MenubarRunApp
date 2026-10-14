import AppKit
import ServiceManagement
import SwiftUI

/// The popup, top to bottom:
///   1. target device of the selected project (click: devices page)
///   2. selected project (click: projects page, searchable, most recently used first)
///   3. git branch row (click: git page) and actions for the selected project:
///      run/stop, hot reload, logs, screenshot, open in IDE… (several projects can run at once)
///   4. Add Folder (⋯ menu: folders, settings)   5. Quit
/// Clicking row 1, 2 or the git row replaces the popup with that row on top and its searchable list below.
struct MenuContentView: View {
    @EnvironmentObject private var simulators: SimulatorStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var runner: BuildRunner

    @AppStorage("showLog") private var showLog = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// A drill-in page (devices, projects, git) replacing the main content, or nil.
    @State private var page: PopupPage? = nil
    @StateObject private var git = GitModel()
    /// Height of the main view; pages use it so the popup doesn't resize while switching.
    @State private var mainHeight: CGFloat = 0
    @Namespace private var rowNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let page {
                pageView(page)
                    .frame(height: max(mainHeight, 440), alignment: .top)
                    .transition(.opacity)
            } else {
                mainContent
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                        }
                    )
                    .transition(.opacity)
            }
        }
        .onPreferenceChange(ContentHeightKey.self) { height in
            if page == nil, height > 0 { mainHeight = height }
        }
        .padding(6)
        .frame(width: 360)
        .environmentObject(git)
        .environment(\.popupNamespace, rowNamespace)
        .onExitCommand { if page != nil { show(nil) } }
        .task(id: projects.selectedProject?.id) { await git.load(projects.selectedProject) }
        .onAppear {
            Task { await simulators.refresh(silent: true) }
        }
        // Closing the popup returns to the main view next time.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            page = nil
            git.clearTransient()
        }
        .onChange(of: launchAtLogin) { enabled in
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private func show(_ newPage: PopupPage?) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { page = newPage }
    }

    @ViewBuilder
    private func pageView(_ page: PopupPage) -> some View {
        switch page {
        case .devices:
            DevicesPage { show(nil) }
        case .projects:
            ProjectsPage { show(nil) }
        case .git:
            GitPage { show(nil) }
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SimulatorRow { show(.devices) }
            if let project = projects.selectedProject {
                RunControls(project: project, showLog: $showLog)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
            RowDivider()
            if projects.projects.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProjectPickerRow { show(.projects) }
                if let project = projects.selectedProject {
                    RowDivider()
                    ActionsSection(project: project, showLog: $showLog) { show(.git) }
                }
            }
            RowDivider()
            AddFolderRow(showLog: $showLog, launchAtLogin: $launchAtLogin)
            RowDivider()
            QuitRow()
        }
    }

    private var emptyMessage: String {
        if projects.folders.isEmpty {
            return "No projects yet. Add a folder with your Xcode, Flutter or Android projects. They're detected automatically."
        }
        return projects.isScanning ? "Scanning folders…" : "No Xcode, Flutter or Android projects found in the tracked folders."
    }
}

// MARK: - Row 2: Project picker

/// The selected project. In the main view it opens the projects page; as the page header it closes it.
struct ProjectPickerRow: View {
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var runner: BuildRunner
    var isOpen = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: projects.selectedProject?.symbolName ?? "folder")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(projects.selectedProject?.name ?? "Select a project")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if runner.runningCount > 0 {
                    Text("\(runner.runningCount) running")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.2)))
                        .foregroundStyle(.green)
                }
                DrillChevron(isOpen: isOpen)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRow()
        .popupMatched("projects")
        .help(isOpen ? "Back" : "Choose another project")
    }

    private var subtitle: String {
        let count = projects.projects.count
        let kind = projects.selectedProject?.kindLabel ?? "Project"
        return "\(kind) · \(count) project\(count == 1 ? "" : "s")"
    }
}

// MARK: - Row 1: Simulator

/// Shows (and lets you change) the run destination of the *selected* project.
/// The menu only lists destinations that project type supports; each project remembers its own choice.
struct SimulatorRow: View {
    @EnvironmentObject private var simulators: SimulatorStore
    @EnvironmentObject private var projects: ProjectStore
    /// True as the devices page header (click goes back).
    var isOpen = false
    let open: () -> Void

    private var project: XcodeProject? { projects.selectedProject }

    /// The selected project's destination (or the global last-used one when no project is selected).
    private var target: Simulator? {
        guard let project else { return simulators.selected }
        return simulators.destination(for: project, chosen: projects.destinationID(for: project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: DeviceSymbol.name(for: target))
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 28, height: 28)
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(target?.name ?? (project == nil ? "Select a simulator" : "No compatible device"))
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Back" : "Choose a device")

                powerButton
                Button(action: open) { DrillChevron(isOpen: isOpen) }
                    .buttonStyle(.plain)
            }

            if let error = simulators.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
            }
        }
        .listRow()
        .popupMatched("devices")
    }

    private var subtitle: String {
        let prefix = project.map { "\($0.name) → " } ?? ""
        guard let sim = target else {
            if simulators.isLoading { return "Loading devices…" }
            return project.map { $0.unsupportedDestinationHint } ?? "Simulator or device"
        }
        if sim.isPhysical {
            return prefix + "\(sim.runtimeName) · " + (sim.isOffline ? "Device offline" : "\(sim.transport ?? "Connected") device")
        }
        let others = runningOthers.count
        return prefix + "\(sim.runtimeName) · \(sim.stateLabel)" + (others > 0 ? " · \(others) other running" : "")
    }

    /// Simulators/emulators that are running but aren't the selected one.
    private var runningOthers: [Simulator] {
        simulators.bootedSimulators.filter { !$0.isPhysical && $0.udid != target?.udid }
    }

    private var statusColor: Color {
        guard let sim = target else { return Color.secondary.opacity(0.6) }
        if sim.isPhysical { return sim.isOffline ? .orange : .blue }
        return sim.isBooted ? .green : Color.secondary.opacity(0.6)
    }

    @ViewBuilder
    private var powerButton: some View {
        if let sim = target {
            if sim.isPhysical {
                Image(systemName: sim.transport == "USB" ? "cable.connector" : "wifi")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(sim.isOffline ? Color.secondary : Color.blue)
                    .help(sim.isOffline ? "Device is not reachable" : "Connected via \(sim.transport ?? "network")")
            } else if simulators.busyUDIDs.contains(sim.udid) || simulators.isLoading {
                ProgressView().controlSize(.small)
            } else {
                // Explicit action label so it's clear what a click will do to *this* simulator.
                Button {
                    Task { await simulators.togglePower(sim) }
                } label: {
                    Label(sim.isBooted ? "Shut Down" : "Boot",
                          systemImage: sim.isBooted ? "stop.fill" : "power")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(sim.isBooted ? .red : .green)
                .help(sim.isBooted ? "Shut down \(sim.name)" : "Boot \(sim.name)")
            }
        }
    }
}

// MARK: - Project list rows (on the projects page)

/// A compact row in the expanded project list. The whole row is a button: click to select.
struct ProjectRow: View {
    let project: XcodeProject
    var isSelected = false
    let onSelect: () -> Void

    @EnvironmentObject private var simulators: SimulatorStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var runner: BuildRunner
    @State private var hovering = false

    private var session: RunSession? { runner.session(for: project.id) }
    private var destination: Simulator? {
        simulators.destination(for: project, chosen: projects.destinationID(for: project))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // Main area is a real button so clicks always register.
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: project.symbolName)
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                ProjectMenuItems(project: project)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            .help("Archive, remove or open")

            RunStateBadge(phase: session?.phase ?? .idle)
                .frame(width: 16)
        }
        .listRow()
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isSelected ? 0.14 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.45 : 0), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .help(project.directory.path.abbreviatingWithTilde)
        .contextMenu { ProjectMenuItems(project: project) }
    }

    private var caption: String {
        let kind = project.isXcode ? (projects.selectedScheme(for: project) ?? "Xcode") : project.kindLabel
        return "\(kind) · → \(destination?.name ?? "no device")"
    }
}

/// Archive / remove / open items, shared by the row's ⋯ menu and right-click menu.
struct ProjectMenuItems: View {
    let project: XcodeProject
    @EnvironmentObject private var projects: ProjectStore

    var body: some View {
        if projects.isArchived(project) {
            Button("Unarchive") { withAnimation { projects.setArchived(project, false) } }
        } else {
            Button("Archive") { withAnimation { projects.setArchived(project, true) } }
        }
        Button("Remove from List") { withAnimation { projects.remove(project) } }
        Divider()
        Button(DeviceTools.ideAction(for: project).title) { DeviceTools.openInIDE(project) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
    }
}

/// Small run-state indicator for list rows (several projects can run at once).
struct RunStateBadge: View {
    let phase: RunPhase

    var body: some View {
        switch phase {
        case .idle:
            Color.clear
        case .attached:
            Image(systemName: "bolt.fill").foregroundStyle(.yellow).help("Running · hot reload ready")
        case .streaming:
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green).help("Running · live logs")
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Launched")
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Last run failed")
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary).help("Stopped")
        default:
            ProgressView().controlSize(.mini).help(phase.title)
        }
    }
}

// MARK: - Run controls (under the device row)

/// Status line, Run / Stop (and hot reload for Flutter) for the selected project.
private struct RunControls: View {
    let project: XcodeProject
    @Binding var showLog: Bool

    @EnvironmentObject private var simulators: SimulatorStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var runner: BuildRunner

    private var scheme: String? { projects.selectedScheme(for: project) }
    private var session: RunSession? { runner.session(for: project.id) }
    private var phase: RunPhase { session?.phase ?? .idle }
    private var isRunningThis: Bool { session?.isRunning ?? false }
    private var destination: Simulator? {
        simulators.destination(for: project, chosen: projects.destinationID(for: project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            primaryButtons

            if !isRunningThis, let blocker = runBlocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            }

            if phase != .idle {
                statusLine
                    .onTapGesture { withAnimation { showLog.toggle() } }
                    .help("Click to show or hide the log")
            }
        }
    }

    // MARK: Run / stop / hot reload

    @ViewBuilder
    private var primaryButtons: some View {
        HStack(spacing: 6) {
            if isRunningThis {
                Button(role: .destructive) {
                    runner.stop(project.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: .command)

                if session?.phase == .streaming {
                    // Rebuild and relaunch; the current app and its log stream are stopped first.
                    Button {
                        run()
                    } label: {
                        Label("Run Again", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(runBlocker != nil)
                    .help("Stop, rebuild and relaunch (⌘R)")
                }

                if session?.canHotReload == true {
                    Button {
                        session?.hotReload()
                    } label: {
                        Label("Hot Reload", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Hot reload (⌘R)")

                    Button {
                        session?.hotRestart()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("Hot restart (⇧⌘R)")
                }
            } else {
                Button {
                    run()
                } label: {
                    Label(runTitle, systemImage: "play.fill")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(runBlocker != nil)
            }
        }
    }

    private var runTitle: String {
        guard let destination else { return "Run" }
        return "Run on \(destination.name)"
    }

    private var runBlocker: String? {
        guard let destination else { return project.unsupportedDestinationHint }
        if !project.supports(destination) { return project.unsupportedDestinationHint }
        if destination.isOffline { return "\(destination.name) is offline" }
        if project.isXcode, scheme == nil { return "Select a scheme first" }
        return nil
    }

    private func run() {
        guard runBlocker == nil, let destination else { return }
        projects.markUsed(project)
        runner.run(project: project, scheme: project.isXcode ? scheme : nil, simulator: destination)
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                PhaseIcon(phase: phase)
                Text(phase.title)
                if let started = session?.startedAt {
                    ElapsedText(start: started, end: session?.finishedAt)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let errors = session?.errorCount, errors > 0 {
                    Text("· \(errors) error\(errors == 1 ? "" : "s")").foregroundStyle(.red)
                }
                if let warnings = session?.warningCount, warnings > 0 {
                    Text("· \(warnings) warning\(warnings == 1 ? "" : "s")").foregroundStyle(.orange)
                }
            }
            if case let .failed(message) = phase {
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isRunningThis, let detail = session?.statusDetail, !detail.isEmpty {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
    }
}

// MARK: - Actions for the selected project

private struct ActionsSection: View {
    let project: XcodeProject
    @Binding var showLog: Bool
    let openGit: () -> Void

    @EnvironmentObject private var simulators: SimulatorStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var runner: BuildRunner
    @State private var screenshotMessage: String? = nil
    @State private var lastScreenshot: URL? = nil
    @State private var isCapturing = false
    /// One-click fix offered on the current error message (e.g. Open Privacy Settings).
    @State private var messageAction: ScreenshotFix? = nil

    private var scheme: String? { projects.selectedScheme(for: project) }
    private var session: RunSession? { runner.session(for: project.id) }
    private var phase: RunPhase { session?.phase ?? .idle }
    private var isRunningThis: Bool { session?.isRunning ?? false }
    private var destination: Simulator? {
        simulators.destination(for: project, chosen: projects.destinationID(for: project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Git (branch + fetch / pull / push) sits above the actions.
            GitSummary(open: openGit)
                .padding(.horizontal, -8)

            HStack(spacing: 6) {
                SectionHeader(title: "Actions", systemImage: "bolt.horizontal")
                Spacer()
                if project.isXcode {
                    Text("Scheme").font(.caption).foregroundStyle(.secondary)
                    schemeMenu
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ActionTile(title: showLog ? "Hide Logs" : "Show Logs", systemImage: "text.alignleft") {
                    withAnimation { showLog.toggle() }
                }
                ActionTile(title: isCapturing ? "Capturing…" : "Screenshot",
                           systemImage: "camera",
                           disabled: isCapturing || !DeviceTools.canScreenshot(destination)) {
                    takeScreenshot()
                }
                .help("Save a screenshot of \(destination?.name ?? "the device") to the Desktop and copy it")
                ActionTile(title: DeviceTools.ideAction(for: project).title,
                           systemImage: DeviceTools.ideAction(for: project).symbol) {
                    DeviceTools.openInIDE(project)
                }
                ActionTile(title: "Browse Files", systemImage: "doc.text.magnifyingglass") {
                    FileBrowserWindow.show(project: project)
                }
                .help("Browse the project's files with syntax highlighting")
                ActionTile(title: "Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.url])
                }
                ActionTile(title: "Open in Terminal", systemImage: "terminal") {
                    DeviceTools.openInTerminal(project)
                }
                if project.isXcode {
                    ActionTile(title: "Reload Schemes", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await projects.loadSchemes(for: project, force: true) }
                    }
                } else {
                    ActionTile(title: "Open Log File", systemImage: "doc.text", disabled: session == nil) {
                        if let session { NSWorkspace.shared.open(session.logURL) }
                    }
                }
            }

            if let screenshotMessage {
                MessageBanner(
                    text: screenshotMessage,
                    isError: lastScreenshot == nil,
                    onTap: revealScreenshot,
                    actionTitle: messageAction?.actionTitle,
                    action: messageFix,
                    onDismiss: {
                        withAnimation {
                            self.screenshotMessage = nil
                            self.messageAction = nil
                        }
                    }
                )
            }

            if showLog {
                LogPanel()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // Messages and prompts don't outlive the popup.
        .onDisappear { clearTransientMessages() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            clearTransientMessages()
        }
    }

    private var messageFix: (() -> Void)? {
        guard let fix = messageAction else { return nil }
        return { confirm(fix) }
    }

    private var revealScreenshot: (() -> Void)? {
        guard let url = lastScreenshot else { return nil }
        return { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func clearTransientMessages() {
        screenshotMessage = nil
        lastScreenshot = nil
        messageAction = nil
    }

    private func confirm(_ fix: ScreenshotFix) {
        messageAction = nil
        screenshotMessage = nil
        switch fix {
        case .openDesktopPrivacy:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Screenshot

    private func takeScreenshot() {
        guard let destination else { return }
        screenshotMessage = nil
        messageAction = nil
        isCapturing = true
        Task {
            do {
                let url = try await DeviceTools.screenshot(of: destination, label: "\(project.name) – \(destination.name)")
                DeviceTools.copyImage(at: url)
                lastScreenshot = url
                screenshotMessage = "Saved to Desktop and copied. Click to reveal."
            } catch let error as ScreenshotError {
                lastScreenshot = nil
                screenshotMessage = error.localizedDescription
                switch error {
                case .desktopPermission: messageAction = .openDesktopPrivacy
                }
            } catch {
                lastScreenshot = nil
                screenshotMessage = error.localizedDescription
            }
            isCapturing = false
        }
    }

    // MARK: Scheme & status

    @ViewBuilder
    private var schemeMenu: some View {
        if projects.loadingSchemes.contains(project.id) {
            ProgressView().controlSize(.mini)
        } else if let list = projects.schemes[project.id], !list.isEmpty {
            Menu {
                Picker("Scheme", selection: Binding(
                    get: { scheme },
                    set: { projects.setScheme($0, for: project) }
                )) {
                    ForEach(list, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Reload Schemes") {
                    Task { await projects.loadSchemes(for: project, force: true) }
                }
            } label: {
                Text(scheme ?? "Select").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else if let error = projects.schemeErrors[project.id] {
            Text("No schemes").font(.caption).foregroundStyle(.red).help(error)
        } else {
            Text("…").font(.caption)
        }
    }

}

/// One-click fixes offered on a screenshot error message.
private enum ScreenshotFix {
    case openDesktopPrivacy

    var actionTitle: String {
        switch self {
        case .openDesktopPrivacy: return "Open Privacy Settings"
        }
    }
}

/// Success / error message with an ✕ to dismiss it. Tapping the text runs `onTap` (e.g. reveal the file).
struct MessageBanner: View {
    let text: String
    let isError: Bool
    var onTap: (() -> Void)?
    /// Optional one-click fix shown under the message (e.g. "Install").
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            messageRow
            if let actionTitle, let action {
                HStack {
                    Spacer()
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((isError ? Color.red : Color.green).opacity(0.08))
        )
    }

    private var messageRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.green)
            Text(text)
                .font(.caption)
                .foregroundStyle(isError ? Color.red : Color.primary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .onTapGesture { onTap?() }
                .help(onTap == nil ? "" : "Reveal in Finder")
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }
}

struct ActionTile: View {
    let title: String
    let systemImage: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(disabled ? Color.secondary : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(hovering && !disabled ? 0.12 : 0.06))
        )
        .onHover { hovering = $0 }
        .disabled(disabled)
    }
}

private struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - Last row: Add Folder

private struct AddFolderRow: View {
    @EnvironmentObject private var simulators: SimulatorStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var runner: BuildRunner
    @Binding var showLog: Bool
    @Binding var launchAtLogin: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                projects.presentAddPanel()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    Text("Add Folder…")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if projects.isScanning {
                ProgressView().controlSize(.small)
            }

            Menu {
                Button(showLog ? "Hide Build Log" : "Show Build Log") {
                    withAnimation { showLog.toggle() }
                }
                Button("Open Log File") {
                    if let id = projects.selectedProjectID, let session = runner.session(for: id) {
                        NSWorkspace.shared.open(session.logURL)
                    } else {
                        NSWorkspace.shared.open(runner.logsDirectory)
                    }
                }
                if runner.runningCount > 1 {
                    Button("Stop All Runs (\(runner.runningCount))") { runner.stopAll() }
                }
                Button("Refresh") {
                    Task {
                        await simulators.refresh()
                        await projects.rescan()
                    }
                }
                Divider()
                Menu("Tracked Folders (\(projects.folders.count))") {
                    if projects.folders.isEmpty {
                        Text("No folders yet")
                    }
                    ForEach(projects.folders, id: \.self) { folder in
                        Menu(folder.path.abbreviatingWithTilde) {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([folder])
                            }
                            Button("Remove") { projects.removeFolder(folder) }
                        }
                    }
                }
                if !projects.removedProjects.isEmpty {
                    Menu("Removed Projects (\(projects.removedProjects.count))") {
                        ForEach(projects.removedProjects) { project in
                            Button("Restore \(project.name)") { projects.restore(project) }
                        }
                        Divider()
                        Button("Restore All") { projects.restoreAllRemoved() }
                    }
                }
                Toggle("Launch at Login", isOn: $launchAtLogin)
                Divider()
                Button("Quit RunXcodeApp") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .listRow()
    }
}

// MARK: - Log panel

/// Build log of the selected project's run session.
private struct LogPanel: View {
    @EnvironmentObject private var runner: BuildRunner
    @EnvironmentObject private var projects: ProjectStore

    private var session: RunSession? { projects.selectedProjectID.flatMap { runner.session(for: $0) } }
    private var lines: [String] { session?.logLines ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(projects.selectedProject.map { "Log · \($0.name)" } ?? "Log · select a project")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Self.color(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(6)
                    .textSelection(.enabled)
                }
                .frame(height: 200)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .onChange(of: session?.logRevision ?? 0) { _ in
                    if let last = lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            HStack {
                Button("Open Full Log") { NSWorkspace.shared.open(session?.logURL ?? runner.logsDirectory) }
                Button("Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Text("\(lines.count) lines").font(.caption2).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }

    private static func color(for line: String) -> Color {
        if line.contains(": error:") || line.hasPrefix("✗") || line.contains("** BUILD FAILED **") { return .red }
        if line.contains(": warning:") { return .orange }
        if line.hasPrefix("✓") || line.contains("** BUILD SUCCEEDED **") { return .green }
        if line.hasPrefix("$ ") || line.hasPrefix("▶") { return .accentColor }
        return .primary
    }
}

// MARK: - Shared pieces

struct ListRowStyle: ViewModifier {
    var verticalPadding: CGFloat = 7
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension View {
    func listRow() -> some View { modifier(ListRowStyle()) }
    /// Tighter rows for long lists on drill-in pages.
    func compactListRow() -> some View { modifier(ListRowStyle(verticalPadding: 4)) }
}

// MARK: - Last row: Quit

private struct QuitRow: View {
    var body: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "power")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                Text("Quit RunXcodeApp")
                Spacer()
                Text("⌘Q")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q", modifiers: .command)
        .listRow()
        .help("Quit the menu bar app")
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 8).padding(.vertical, 3)
    }
}

private struct PhaseIcon: View {
    let phase: RunPhase

    var body: some View {
        switch phase {
        case .idle:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
        case .attached:
            Image(systemName: "bolt.fill").foregroundStyle(.yellow)
        case .streaming:
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
        default:
            ProgressView().controlSize(.mini)
        }
    }
}

private struct ElapsedText: View {
    let start: Date
    let end: Date?

    var body: some View {
        if let end {
            Text(Self.format(end.timeIntervalSince(start)))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.format(context.date.timeIntervalSince(start)))
            }
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
