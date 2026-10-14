import AppKit
import ServiceManagement
import SwiftUI

/// The popup, top to bottom:
///   1. target device of the selected project (filtered to what that project type supports)
///   2. collapsible project picker: shows the selected project; expand to pick another
///      (most recently used first, collapsible "Archived" section)
///   3. actions for the selected project: run/stop, hot reload, logs, screenshot, open in IDE…
///      (several projects can run at once)
///   4. Add Folder (⋯ menu: folders, settings)   5. Quit
struct MenuContentView: View {
    @EnvironmentObject private var simulators: SimulatorStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var runner: BuildRunner

    @AppStorage("showLog") private var showLog = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("archivedExpanded") private var archivedExpanded = false
    /// The project list is collapsed by default; it shows only the selected project.
    @AppStorage("projectListExpanded") private var projectListExpanded = false

    private let rowSpacing: CGFloat = 2

    private let maxVisibleRows = 7
    private let rowHeight: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SimulatorRow()
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
                projectPickerHeader
                if projectListExpanded {
                    projectList
                        .padding(.leading, 12)
                        .transition(.opacity)
                }
                if let project = projects.selectedProject {
                    RowDivider()
                    ActionsSection(project: project, showLog: $showLog)
                }
            }
            RowDivider()
            AddFolderRow(showLog: $showLog, launchAtLogin: $launchAtLogin)
            RowDivider()
            QuitRow()
        }
        .padding(6)
        .frame(width: 360)
        .onAppear {
            Task { await simulators.refresh(silent: true) }
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

    /// Collapsed: the selected project. Click to expand the full list.
    private var projectPickerHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { projectListExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: projects.selectedProject?.symbolName ?? "folder")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(projects.selectedProject?.name ?? "Select a project")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(pickerSubtitle)
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
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(projectListExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRow()
        .help(projectListExpanded ? "Collapse project list" : "Choose another project")
    }

    private var pickerSubtitle: String {
        let count = projects.projects.count
        let kind = projects.selectedProject?.kindLabel ?? "Project"
        return "\(kind) · \(count) project\(count == 1 ? "" : "s") · click to \(projectListExpanded ? "collapse" : "switch")"
    }

    @ViewBuilder
    private var projectList: some View {
        if visibleRowCount > maxVisibleRows {
            ScrollView { projectSections }
                .frame(height: CGFloat(maxVisibleRows) * rowHeight)
        } else {
            projectSections
        }
    }

    private var visibleRowCount: Int {
        let archived = projects.archivedProjects
        return projects.activeProjects.count
            + (archived.isEmpty ? 0 : 1)
            + (archivedExpanded ? archived.count : 0)
    }

    private var projectSections: some View {
        VStack(spacing: rowSpacing) {
            if projects.activeProjects.isEmpty {
                Text("All projects are archived.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(projects.activeProjects) { project in
                projectRow(project)
            }

            if !projects.archivedProjects.isEmpty {
                archivedHeader
                if archivedExpanded {
                    ForEach(projects.archivedProjects) { project in
                        projectRow(project)
                    }
                }
            }
        }
    }

    private func projectRow(_ project: XcodeProject) -> some View {
        ProjectRow(project: project, isSelected: projects.selectedProjectID == project.id) {
            // Selecting also moves it to the top (last used first) and collapses the list.
            projects.selectedProjectID = project.id
            withAnimation(.easeInOut(duration: 0.15)) { projectListExpanded = false }
        }
    }

    private var archivedHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { archivedExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(archivedExpanded ? 90 : 0))
                    .frame(width: 28)
                Image(systemName: "archivebox")
                Text("Archived")
                Text("\(projects.archivedProjects.count)").foregroundStyle(.tertiary)
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRow()
        .help("Projects you archived (⋯ › Archive). Click to show or hide.")
    }

    private var emptyMessage: String {
        if projects.folders.isEmpty {
            return "No projects yet. Add a folder with your Xcode, Flutter or Android projects. They're detected automatically."
        }
        return projects.isScanning ? "Scanning folders…" : "No Xcode, Flutter or Android projects found in the tracked folders."
    }
}

// MARK: - Row 1: Simulator

/// Shows (and lets you change) the run destination of the *selected* project.
/// The menu only lists destinations that project type supports; each project remembers its own choice.
private struct SimulatorRow: View {
    @EnvironmentObject private var simulators: SimulatorStore
    @EnvironmentObject private var projects: ProjectStore

    private var project: XcodeProject? { projects.selectedProject }

    /// The selected project's destination (or the global last-used one when no project is selected).
    private var target: Simulator? {
        guard let project else { return simulators.selected }
        return simulators.destination(for: project, chosen: projects.destinationID(for: project))
    }

    private var targetBinding: Binding<String?> {
        Binding(
            get: { target?.udid },
            set: { udid in
                if let project { projects.setDestination(udid, for: project) }
                simulators.selectedUDID = udid  // also the default for projects without a choice
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: deviceSymbol)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Menu {
                        let running = runningOthers + (target.map { $0.isBooted && !$0.isPhysical ? [$0] : [] } ?? [])
                        if !running.isEmpty {
                            Section("Running") {
                                ForEach(running) { sim in
                                    Button("Shut Down \(sim.name)") {
                                        Task { await simulators.shutdown(sim) }
                                    }
                                }
                                if running.count > 1 {
                                    Button("Shut Down All") {
                                        Task { await simulators.shutdownAll() }
                                    }
                                }
                            }
                            Divider()
                        }
                        Picker("Simulator", selection: targetBinding) {
                            ForEach(simulators.groups(for: project)) { group in
                                Section(group.name) {
                                    ForEach(group.simulators) { sim in
                                        Text(sim.menuTitle)
                                            .tag(String?.some(sim.udid))
                                    }
                                }
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        Divider()
                        Button("Refresh Devices") {
                            Task { await simulators.refresh() }
                        }
                    } label: {
                        Text(target?.name ?? (project == nil ? "Select a simulator" : "No compatible device"))
                            .font(.body.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                powerButton
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

    private var deviceSymbol: String {
        guard let sim = target else { return "iphone" }
        switch sim.platform {
        case "Android": return "candybarphone"
        case "watchOS": return "applewatch"
        case "tvOS": return "appletv"
        case "visionOS": return "eyeglasses"
        default: return sim.name.contains("iPad") ? "ipad" : "iphone"
        }
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

// MARK: - Project list rows (inside the collapsible project picker)

/// A compact row in the expanded project list. The whole row is a button: click to select.
private struct ProjectRow: View {
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
private struct ProjectMenuItems: View {
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
private struct RunStateBadge: View {
    let phase: RunPhase

    var body: some View {
        switch phase {
        case .idle:
            Color.clear
        case .attached:
            Image(systemName: "bolt.fill").foregroundStyle(.yellow).help("Running · hot reload ready")
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

// MARK: - Actions for the selected project

private struct ActionsSection: View {
    let project: XcodeProject
    @Binding var showLog: Bool

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
            GitPanel(project: project)
                .id(project.id)

            HStack(spacing: 6) {
                SectionHeader(title: "Actions", systemImage: "bolt.horizontal")
                Spacer()
                if project.isXcode {
                    Text("Scheme").font(.caption).foregroundStyle(.secondary)
                    schemeMenu
                }
            }

            if phase != .idle {
                statusLine
                    .onTapGesture { withAnimation { showLog.toggle() } }
                    .help("Click to show or hide the log")
            }

            primaryButtons

            if !isRunningThis, let blocker = runBlocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
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
private struct MessageBanner: View {
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

// MARK: - Git (current branch, fetch / pull / push, switch & create branches)

private struct GitPanel: View {
    let project: XcodeProject

    @State private var status: GitStatus? = nil
    @State private var busy: String? = nil
    @State private var message: String? = nil
    @State private var messageIsError = false
    @State private var isCreatingBranch = false
    @State private var newBranchName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status {
                HStack(spacing: 8) {
                    branchMenu(status)
                    Text(busy ?? syncSummary(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if busy != nil {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh git status")
                    }
                }

                HStack(spacing: 6) {
                    ActionTile(title: "Fetch", systemImage: "arrow.down.circle", disabled: busy != nil) {
                        perform("Fetching…", success: "Fetched.") { try await Git.fetch(status) }
                    }
                    ActionTile(title: status.behind > 0 ? "Pull ↓\(status.behind)" : "Pull",
                               systemImage: "arrow.down.to.line",
                               disabled: busy != nil || status.upstream == nil || status.isDetached) {
                        perform("Pulling…", success: "Pulled \(status.branch).") { try await Git.pull(status) }
                    }
                    .help(status.upstream == nil ? "This branch has no upstream yet. Push it first." : "git pull --ff-only")
                    ActionTile(title: status.ahead > 0 ? "Push ↑\(status.ahead)" : "Push",
                               systemImage: "arrow.up.to.line",
                               disabled: busy != nil || status.isDetached) {
                        perform("Pushing…", success: "Pushed \(status.branch).") { try await Git.push(status) }
                    }
                    .help(status.upstream == nil ? "Push and set upstream (git push -u)" : "git push")
                }

                if isCreatingBranch {
                    HStack(spacing: 6) {
                        TextField("new-branch-name", text: $newBranchName)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)
                            .onSubmit { createBranch(from: status) }
                        Button("Create") { createBranch(from: status) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty || busy != nil)
                        Button {
                            isCreatingBranch = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Cancel")
                    }
                    Text("Creates the branch from \(status.branch) and switches to it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let message {
                    MessageBanner(text: message, isError: messageIsError, onDismiss: {
                        withAnimation { self.message = nil }
                    })
                }

                Divider()
            } else {
                // Not a git repository (or not loaded yet): show nothing.
                Color.clear.frame(height: 0)
            }
        }
        .task(id: project.id) { await refresh() }
        .onDisappear { message = nil; isCreatingBranch = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            message = nil
        }
    }

    private func branchMenu(_ status: GitStatus) -> some View {
        Menu {
            Section("Local Branches") {
                ForEach(status.localBranches, id: \.self) { branch in
                    Button {
                        perform("Switching…", success: "Switched to \(branch).") {
                            try await Git.switchTo(branch, in: status)
                        }
                    } label: {
                        if branch == status.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                    .disabled(branch == status.branch)
                }
            }
            if !status.remoteBranches.isEmpty {
                Menu("Remote Branches") {
                    ForEach(status.remoteBranches, id: \.self) { remote in
                        Button(remote) {
                            perform("Checking out…", success: "Switched to \(remote).") {
                                try await Git.checkoutRemote(remote, in: status)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("New Branch from \(status.isDetached ? "HEAD" : status.branch)…") {
                newBranchName = ""
                withAnimation { isCreatingBranch = true }
            }
        } label: {
            Label(status.isDetached ? "detached HEAD" : status.branch, systemImage: "arrow.triangle.branch")
                .font(.callout.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(busy != nil)
        .help("Switch branch or create a new one")
    }

    private func syncSummary(_ status: GitStatus) -> String {
        var parts: [String] = []
        if let upstream = status.upstream {
            parts.append(status.ahead == 0 && status.behind == 0 ? "up to date with \(upstream)" : "↑\(status.ahead) ↓\(status.behind)")
        } else if !status.isDetached {
            parts.append("not pushed yet")
        }
        if status.changes > 0 { parts.append("\(status.changes) changed") }
        return parts.joined(separator: " · ")
    }

    private func createBranch(from status: GitStatus) {
        let name = newBranchName
        perform("Creating branch…", success: "Created and switched to \(name.trimmingCharacters(in: .whitespaces)).") {
            try await Git.createBranch(name, in: status)
        }
        isCreatingBranch = false
    }

    private func perform(_ label: String, success: String, _ operation: @escaping () async throws -> Void) {
        guard busy == nil else { return }
        busy = label
        message = nil
        Task {
            do {
                try await operation()
                message = success
                messageIsError = false
            } catch {
                message = error.localizedDescription
                messageIsError = true
            }
            busy = nil
            await refresh()
        }
    }

    private func refresh() async {
        status = await Git.status(for: project.directory)
    }
}

private struct ActionTile: View {
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

private struct ListRowStyle: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private extension View {
    func listRow() -> some View { modifier(ListRowStyle()) }
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
