import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The popup is a single list:
///   1. selected simulator
///   2…n. one row per project, each with its own Run button (drag to reorder)
///   then a collapsible "Archived" section (collapsed by default)
///   last. Add Folder (plus a ⋯ menu for log, folders, settings, quit)
struct MenuContentView: View {
    @EnvironmentObject private var simulators: SimulatorStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var runner: BuildRunner

    @AppStorage("showLog") private var showLog = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("archivedExpanded") private var archivedExpanded = false
    @State private var draggingID: String?

    private let maxVisibleRows = 7
    private let rowHeight: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SimulatorRow()
            RowDivider()
            projectList
            RowDivider()
            AddFolderRow(showLog: $showLog, launchAtLogin: $launchAtLogin)
            if showLog {
                LogPanel()
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
            }
        }
        .padding(6)
        .frame(width: 360)
        .onAppear {
            draggingID = nil
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

    @ViewBuilder
    private var projectList: some View {
        if projects.projects.isEmpty {
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if visibleRowCount > maxVisibleRows {
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
        VStack(spacing: 2) {
            if projects.activeProjects.isEmpty {
                Text("All projects are archived.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(projects.activeProjects) { project in
                draggableRow(project)
            }

            if !projects.archivedProjects.isEmpty {
                archivedHeader
                if archivedExpanded {
                    ForEach(projects.archivedProjects) { project in
                        draggableRow(project)
                    }
                }
            }
        }
        // Dropping outside a row still ends the drag.
        .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(onEnter: {}, onDrop: { draggingID = nil }))
    }

    private func draggableRow(_ project: XcodeProject) -> some View {
        ProjectRow(project: project)
            .opacity(draggingID == project.id ? 0.4 : 1)
            .onDrag {
                draggingID = project.id
                return NSItemProvider(object: project.id as NSString)
            }
            .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(
                onEnter: {
                    guard let dragged = draggingID, dragged != project.id else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        projects.move(dragged, to: project.id)
                    }
                },
                onDrop: { draggingID = nil }
            ))
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
        .help("Drop a project here to archive it")
        // Dropping a project on the header archives it.
        .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(
            onEnter: {},
            onDrop: {
                if let dragged = draggingID,
                   let project = projects.projects.first(where: { $0.id == dragged }) {
                    withAnimation { projects.setArchived(project, true) }
                }
                draggingID = nil
            }
        ))
    }

    private var emptyMessage: String {
        if projects.folders.isEmpty {
            return "No projects yet. Add a folder that contains your Xcode projects (.xcodeproj / .xcworkspace)."
        }
        return projects.isScanning ? "Scanning folders…" : "No Xcode projects found in the tracked folders."
    }
}

// MARK: - Row 1: Simulator

private struct SimulatorRow: View {
    @EnvironmentObject private var simulators: SimulatorStore

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
                        Picker("Simulator", selection: $simulators.selectedUDID) {
                            ForEach(simulators.groups) { group in
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
                        Text(simulators.selected?.name ?? "Select a simulator")
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
        guard let sim = simulators.selected else {
            return simulators.isLoading ? "Loading devices…" : "Simulator or device"
        }
        if sim.isPhysical {
            return "\(sim.runtimeName) · " + (sim.isOffline ? "Device offline" : "\(sim.transport ?? "Connected") device")
        }
        return "\(sim.runtimeName) · \(sim.isBooted ? "Booted" : "Shut down")"
    }

    private var statusColor: Color {
        guard let sim = simulators.selected else { return Color.secondary.opacity(0.6) }
        if sim.isPhysical { return sim.isOffline ? .orange : .blue }
        return sim.isBooted ? .green : Color.secondary.opacity(0.6)
    }

    private var deviceSymbol: String {
        guard let sim = simulators.selected else { return "iphone" }
        switch sim.platform {
        case "watchOS": return "applewatch"
        case "tvOS": return "appletv"
        case "visionOS": return "eyeglasses"
        default: return sim.name.contains("iPad") ? "ipad" : "iphone"
        }
    }

    @ViewBuilder
    private var powerButton: some View {
        if let sim = simulators.selected {
            if sim.isPhysical {
                Image(systemName: sim.transport == "USB" ? "cable.connector" : "wifi")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(sim.isOffline ? Color.secondary : Color.blue)
                    .help(sim.isOffline ? "Device is not reachable" : "Connected via \(sim.transport ?? "network")")
            } else if simulators.busyUDIDs.contains(sim.udid) || simulators.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task {
                        if sim.isBooted { await simulators.shutdown(sim) } else { await simulators.boot(sim) }
                    }
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(sim.isBooted ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(sim.isBooted ? "Shut down \(sim.name)" : "Boot \(sim.name)")
            }
        }
    }
}

// MARK: - Project rows

private struct ProjectRow: View {
    let project: XcodeProject

    @EnvironmentObject private var simulators: SimulatorStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var runner: BuildRunner
    @AppStorage("showLog") private var showLog = false
    @State private var hovering = false

    private var scheme: String? { projects.selectedScheme(for: project) }
    private var isActive: Bool { runner.projectID == project.id && runner.phase != .idle }
    private var isRunningThis: Bool { runner.projectID == project.id && runner.isRunning }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: project.kind == .workspace ? "square.stack.3d.up.fill" : "hammer.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    schemeMenu
                    Text("·").foregroundStyle(.tertiary)
                    Text(project.directory.path.abbreviatingWithTilde)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if isActive {
                    statusLine
                        .onTapGesture { withAnimation { showLog.toggle() } }
                        .help("Click to show or hide the build log")
                }
            }

            Spacer(minLength: 4)

            // Row actions, revealed on hover (same items as the right-click menu).
            Menu {
                actionItems
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            .help("Move, archive or remove")

            runButton
        }
        .listRow()
        .onHover { hovering = $0 }
        .contextMenu { actionItems }
    }

    @ViewBuilder
    private var actionItems: some View {
        if let scheme, let sim = simulators.selected, !runner.isRunning {
            Button("Run \(scheme) on \(sim.name)") { run() }
            Divider()
        }
        Button("Move to Top") { withAnimation { projects.moveToTop(project) } }
            .disabled(!projects.canMove(project, by: -1))
        Button("Move Up") { withAnimation { projects.move(project, by: -1) } }
            .disabled(!projects.canMove(project, by: -1))
        Button("Move Down") { withAnimation { projects.move(project, by: 1) } }
            .disabled(!projects.canMove(project, by: 1))
        Divider()
        if projects.isArchived(project) {
            Button("Unarchive") { withAnimation { projects.setArchived(project, false) } }
        } else {
            Button("Archive") { withAnimation { projects.setArchived(project, true) } }
        }
        Button("Remove from List") { withAnimation { projects.remove(project) } }
        Divider()
        Button("Open in Xcode") { NSWorkspace.shared.open(project.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
        Button("Reload Schemes") {
            Task { await projects.loadSchemes(for: project, force: true) }
        }
    }

    // Scheme selector shown inline under the project name.
    @ViewBuilder
    private var schemeMenu: some View {
        if projects.loadingSchemes.contains(project.id) {
            Text("Loading schemes…")
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
                Text(scheme ?? "Select scheme").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else if let error = projects.schemeErrors[project.id] {
            Text("No schemes")
                .foregroundStyle(.red)
                .help(error)
        } else {
            Text("…")
        }
    }

    @ViewBuilder
    private var runButton: some View {
        if isRunningThis {
            Button {
                runner.stop()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop")
        } else {
            Button {
                run()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(runBlocker == nil ? Color.accentColor : Color.secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(runBlocker != nil)
            .help(runBlocker ?? "Run \(scheme ?? "") on \(simulators.selected?.name ?? "")")
        }
    }

    private var runBlocker: String? {
        if runner.isRunning { return "Another run is in progress" }
        if simulators.selected == nil { return "Select a simulator or device first" }
        if scheme == nil { return "Select a scheme first" }
        return nil
    }

    private func run() {
        guard let simulator = simulators.selected, let scheme else { return }
        runner.run(project: project, scheme: scheme, simulator: simulator)
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                PhaseIcon(phase: runner.phase)
                Text(runner.phase.title)
                if let started = runner.startedAt {
                    ElapsedText(start: started, end: runner.finishedAt)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if runner.errorCount > 0 {
                    Text("· \(runner.errorCount) error\(runner.errorCount == 1 ? "" : "s")").foregroundStyle(.red)
                }
                if runner.warningCount > 0 {
                    Text("· \(runner.warningCount) warning\(runner.warningCount == 1 ? "" : "s")").foregroundStyle(.orange)
                }
            }

            if case let .failed(message) = runner.phase {
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if runner.isRunning, !runner.statusDetail.isEmpty {
                Text(runner.statusDetail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
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
                Button("Open Log File") { NSWorkspace.shared.open(runner.logURL) }
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
                    .keyboardShortcut("q")
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

private struct LogPanel: View {
    @EnvironmentObject private var runner: BuildRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(runner.logLines.enumerated()), id: \.offset) { index, line in
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
                .onChange(of: runner.logRevision) { _ in
                    if let last = runner.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            HStack {
                Button("Open Full Log") { NSWorkspace.shared.open(runner.logURL) }
                Button("Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(runner.logLines.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Text("\(runner.logLines.count) lines").font(.caption2).foregroundStyle(.secondary)
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

private struct ReorderDropDelegate: DropDelegate {
    let onEnter: () -> Void
    let onDrop: () -> Void

    func dropEntered(info: DropInfo) { onEnter() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        onDrop()
        return true
    }
}

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
