import SwiftUI

/// Which drill-in page replaces the main popup content.
enum PopupPage: Equatable {
    case devices
    case projects
    case git
}

// MARK: - Shared pieces

/// Trailing chevron on drill-in rows: › in the main view, ⌃ (back) on the page header.
struct DrillChevron: View {
    let isOpen: Bool

    var body: some View {
        Image(systemName: isOpen ? "chevron.up" : "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 12)
    }
}

/// Search box that takes focus when the page opens. Return runs `onSubmit`.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(focused ? 0.25 : 0.1)))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }
}

/// A scroll view as tall as its content, up to `maxHeight`.
struct BoundedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PageSectionTitle: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let count { Text("\(count)").foregroundStyle(.tertiary) }
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

// MARK: - Devices page

/// Device row on top, then a searchable list of the destinations the selected project supports.
struct DevicesPage: View {
    @EnvironmentObject private var simulators: SimulatorStore
    @EnvironmentObject private var projects: ProjectStore
    let close: () -> Void

    @State private var search = ""

    private var project: XcodeProject? { projects.selectedProject }
    private var target: Simulator? {
        guard let project else { return simulators.selected }
        return simulators.destination(for: project, chosen: projects.destinationID(for: project))
    }

    private var filteredGroups: [RuntimeGroup] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let groups = simulators.groups(for: project)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let groupMatches = group.name.localizedCaseInsensitiveContains(query)
            let sims = groupMatches ? group.simulators
                : group.simulators.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return sims.isEmpty ? nil
                : RuntimeGroup(id: group.id, platform: group.platform, version: group.version, simulators: sims)
        }
    }

    private var running: [Simulator] {
        simulators.bootedSimulators.filter { !$0.isPhysical }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SimulatorRow(isOpen: true, open: close)

            HStack(spacing: 6) {
                SearchField(text: $search, prompt: "Search devices and runtimes") {
                    if let first = filteredGroups.first?.simulators.first { select(first) }
                }
                Button {
                    Task { await simulators.refresh() }
                } label: {
                    if simulators.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .frame(width: 22)
                .help("Refresh devices")
            }
            .padding(.horizontal, 8)

            BoundedScrollView(maxHeight: 380) {
                VStack(alignment: .leading, spacing: 2) {
                    if search.isEmpty && !running.isEmpty {
                        runningSection
                    }
                    if filteredGroups.isEmpty {
                        Text(search.isEmpty ? (project?.unsupportedDestinationHint ?? "No devices found.")
                                            : "No devices match “\(search)”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    ForEach(filteredGroups) { group in
                        PageSectionTitle(title: group.name)
                        ForEach(group.simulators) { sim in
                            DeviceListRow(device: sim, isSelected: sim.udid == target?.udid) { select(sim) }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                PageSectionTitle(title: "Running", count: running.count)
                if running.count > 1 {
                    Button("Shut Down All") { Task { await simulators.shutdownAll() } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.top, 6)
                        .padding(.trailing, 10)
                }
            }
            ForEach(running) { sim in
                HStack(spacing: 10) {
                    Circle().fill(.green).frame(width: 7, height: 7).frame(width: 28)
                    Text(sim.name).lineLimit(1)
                    Text(sim.runtimeName).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if simulators.busyUDIDs.contains(sim.udid) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Shut Down") { Task { await simulators.shutdown(sim) } }
                            .controlSize(.small)
                            .tint(.red)
                    }
                }
                .compactListRow()
            }
        }
    }

    private func select(_ sim: Simulator) {
        if let project { projects.setDestination(sim.udid, for: project) }
        simulators.selectedUDID = sim.udid
        close()
    }
}

private struct DeviceListRow: View {
    let device: Simulator
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: DeviceSymbol.name(for: device))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.name)
                        .font(isSelected ? .body.weight(.semibold) : .body)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if device.isBooted && !device.isPhysical {
                    Circle().fill(.green).frame(width: 7, height: 7).help("Running")
                }
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .compactListRow()
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(isSelected ? 0.12 : 0)))
    }

    private var detail: String {
        if device.isPhysical {
            return device.isOffline ? "Offline" : "\(device.transport ?? "Connected") device"
        }
        return device.stateLabel
    }
}

enum DeviceSymbol {
    static func name(for device: Simulator?) -> String {
        guard let device else { return "iphone" }
        switch device.platform {
        case "Android": return "candybarphone"
        case "watchOS": return "applewatch"
        case "tvOS": return "appletv"
        case "visionOS": return "eyeglasses"
        default: return device.name.contains("iPad") ? "ipad" : "iphone"
        }
    }
}

// MARK: - Projects page

/// Selected project on top, then a searchable list of all projects (archived ones in their own section).
struct ProjectsPage: View {
    @EnvironmentObject private var projects: ProjectStore
    let close: () -> Void

    @AppStorage("archivedExpanded") private var archivedExpanded = false
    @State private var search = ""

    private func matches(_ project: XcodeProject) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return project.name.localizedCaseInsensitiveContains(query)
            || project.kindLabel.localizedCaseInsensitiveContains(query)
            || project.directory.path.localizedCaseInsensitiveContains(query)
    }

    private var active: [XcodeProject] { projects.activeProjects.filter(matches) }
    private var archived: [XcodeProject] { projects.archivedProjects.filter(matches) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProjectPickerRow(isOpen: true, action: close)

            SearchField(text: $search, prompt: "Search projects") {
                if let first = active.first ?? archived.first { select(first) }
            }
            .padding(.horizontal, 8)

            BoundedScrollView(maxHeight: 400) {
                VStack(alignment: .leading, spacing: 2) {
                    if active.isEmpty && archived.isEmpty {
                        Text(search.isEmpty ? "All projects are archived." : "No projects match “\(search)”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    ForEach(active) { project in
                        ProjectRow(project: project, isSelected: projects.selectedProjectID == project.id) {
                            select(project)
                        }
                    }
                    if !archived.isEmpty {
                        archivedHeader
                        // While searching, archived matches are always shown.
                        if archivedExpanded || !search.isEmpty {
                            ForEach(archived) { project in
                                ProjectRow(project: project, isSelected: projects.selectedProjectID == project.id) {
                                    select(project)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var archivedHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { archivedExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(archivedExpanded || !search.isEmpty ? 90 : 0))
                    .frame(width: 28)
                Image(systemName: "archivebox")
                Text("Archived")
                Text("\(archived.count)").foregroundStyle(.tertiary)
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRow()
        .disabled(!search.isEmpty)
        .help("Projects you archived (⋯ › Archive). Click to show or hide.")
    }

    private func select(_ project: XcodeProject) {
        // Selecting also moves it to the top (last used first).
        projects.selectedProjectID = project.id
        close()
    }
}
