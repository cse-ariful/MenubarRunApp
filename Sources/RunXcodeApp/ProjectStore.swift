import AppKit
import Foundation

/// Tracks the folders the user added, the Xcode projects found inside them, and the chosen scheme per project.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var folders: [URL] = []
    /// Visible projects (not removed), in the user's order. Includes archived ones.
    @Published private(set) var projects: [XcodeProject] = []
    @Published private(set) var archivedIDs: Set<String> = []
    @Published private(set) var removedIDs: Set<String> = []
    /// Everything the scanner found, before ordering / removal.
    @Published private var scannedProjects: [XcodeProject] = []
    /// User-defined order of project ids (shared by the main list and Archived).
    private var order: [String] = []
    @Published private(set) var isScanning = false
    @Published private(set) var schemes: [String: [String]] = [:]
    @Published private(set) var schemeErrors: [String: String] = [:]
    @Published private(set) var loadingSchemes: Set<String> = []
    @Published private var chosenSchemes: [String: String] = [:]
    @Published var selectedProjectID: String? {
        didSet {
            guard selectedProjectID != oldValue else { return }
            UserDefaults.standard.set(selectedProjectID, forKey: Defaults.selectedProject)
            if let project = selectedProject {
                Task { await loadSchemes(for: project) }
            }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        folders = (defaults.stringArray(forKey: Defaults.trackedFolders) ?? []).map { URL(fileURLWithPath: $0) }
        chosenSchemes = (defaults.dictionary(forKey: Defaults.selectedSchemes) as? [String: String]) ?? [:]
        order = defaults.stringArray(forKey: Defaults.projectOrder) ?? []
        archivedIDs = Set(defaults.stringArray(forKey: Defaults.archivedProjects) ?? [])
        removedIDs = Set(defaults.stringArray(forKey: Defaults.removedProjects) ?? [])
        selectedProjectID = defaults.string(forKey: Defaults.selectedProject)
        Task { await rescan() }
    }

    var selectedProject: XcodeProject? { projects.first { $0.id == selectedProjectID } }

    func selectedScheme(for project: XcodeProject) -> String? { chosenSchemes[project.id] }

    func setScheme(_ scheme: String?, for project: XcodeProject) {
        chosenSchemes[project.id] = scheme
        UserDefaults.standard.set(chosenSchemes, forKey: Defaults.selectedSchemes)
    }

    // MARK: - Folders

    func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add Apple Projects Folder"
        panel.message = "Choose folders containing Xcode, Flutter or Android projects (or pick a project directly)."
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        var changed = false
        for url in urls {
            let standardized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !folders.contains(standardized) else { continue }
            folders.append(standardized)
            // Adding a project directly brings it back if it was removed earlier.
            removedIDs.remove(standardized.path)
            changed = true
        }
        guard changed else { return }
        persistFolders()
        persistLayout()
        Task { await rescan() }
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
        persistFolders()
        Task { await rescan() }
    }

    private func persistFolders() {
        UserDefaults.standard.set(folders.map(\.path), forKey: Defaults.trackedFolders)
    }

    func rescan() async {
        isScanning = true
        let roots = folders
        let found = await Task.detached(priority: .userInitiated) { ProjectScanner.scan(roots) }.value
        scannedProjects = found
        rebuild()
        isScanning = false

        await loadAllSchemes()
    }

    /// Loads schemes one project at a time so we don't spawn many xcodebuild processes at once.
    func loadAllSchemes() async {
        for project in projects {
            await loadSchemes(for: project)
        }
    }

    // MARK: - Ordering, archiving, removing

    var activeProjects: [XcodeProject] { projects.filter { !archivedIDs.contains($0.id) } }
    var archivedProjects: [XcodeProject] { projects.filter { archivedIDs.contains($0.id) } }
    var removedProjects: [XcodeProject] { scannedProjects.filter { removedIDs.contains($0.id) } }

    func isArchived(_ project: XcodeProject) -> Bool { archivedIDs.contains(project.id) }

    /// Live drag-reorder: puts `id` where `targetID` is, adopting the target's section (main / Archived).
    func move(_ id: String, to targetID: String) {
        guard id != targetID,
              let from = order.firstIndex(of: id),
              let to = order.firstIndex(of: targetID) else { return }
        order.remove(at: from)
        order.insert(id, at: to)
        if archivedIDs.contains(targetID) { archivedIDs.insert(id) } else { archivedIDs.remove(id) }
        persistLayout()
        rebuild()
    }

    /// Drag-reorder within a section: places `id` at `index` among its section's visible rows.
    func reorder(_ id: String, toSectionIndex index: Int) {
        var section = (archivedIDs.contains(id) ? archivedProjects : activeProjects).map(\.id)
        guard let current = section.firstIndex(of: id) else { return }
        let target = max(0, min(index, section.count - 1))
        guard target != current else { return }
        section.remove(at: current)
        section.insert(id, at: target)
        // Reuse this section's slots in the global order so other projects keep their places.
        let members = Set(section)
        let slots = order.indices.filter { members.contains(order[$0]) }
        guard slots.count == section.count else { return }
        for (slot, projectID) in zip(slots, section) {
            order[slot] = projectID
        }
        persistLayout()
        rebuild()
    }

    /// Move up (-1) or down (+1) within the project's own section.
    func move(_ project: XcodeProject, by offset: Int) {
        let section = isArchived(project) ? archivedProjects : activeProjects
        guard let index = section.firstIndex(of: project), section.indices.contains(index + offset),
              let a = order.firstIndex(of: project.id),
              let b = order.firstIndex(of: section[index + offset].id) else { return }
        order.swapAt(a, b)
        persistLayout()
        rebuild()
    }

    func moveToTop(_ project: XcodeProject) {
        let section = isArchived(project) ? archivedProjects : activeProjects
        guard let first = section.first, first != project else { return }
        move(project.id, to: first.id)
    }

    func canMove(_ project: XcodeProject, by offset: Int) -> Bool {
        let section = isArchived(project) ? archivedProjects : activeProjects
        guard let index = section.firstIndex(of: project) else { return false }
        return section.indices.contains(index + offset)
    }

    func setArchived(_ project: XcodeProject, _ archived: Bool) {
        if archived { archivedIDs.insert(project.id) } else { archivedIDs.remove(project.id) }
        persistLayout()
        rebuild()
    }

    /// Hides the project from the list. If it was added directly (not via a parent folder), stops tracking it.
    func remove(_ project: XcodeProject) {
        if let folder = folders.first(where: { $0.path == project.url.path }) {
            archivedIDs.remove(project.id)
            persistLayout()
            removeFolder(folder)
            return
        }
        removedIDs.insert(project.id)
        persistLayout()
        rebuild()
    }

    func restore(_ project: XcodeProject) {
        removedIDs.remove(project.id)
        persistLayout()
        rebuild()
        Task { await loadSchemes(for: project) }
    }

    func restoreAllRemoved() {
        let restored = removedProjects
        removedIDs.removeAll()
        persistLayout()
        rebuild()
        Task { for project in restored { await loadSchemes(for: project) } }
    }

    private func rebuild() {
        // New projects go to the end, alphabetically (the scanner already sorts by name).
        let known = Set(order)
        let newIDs = scannedProjects.map(\.id).filter { !known.contains($0) }
        if !newIDs.isEmpty {
            order += newIDs
            persistLayout()
        }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        projects = scannedProjects
            .filter { !removedIDs.contains($0.id) }
            .sorted { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
    }

    private func persistLayout() {
        let defaults = UserDefaults.standard
        defaults.set(order, forKey: Defaults.projectOrder)
        defaults.set(Array(archivedIDs), forKey: Defaults.archivedProjects)
        defaults.set(Array(removedIDs), forKey: Defaults.removedProjects)
    }

    // MARK: - Schemes

    func loadSchemes(for project: XcodeProject, force: Bool = false) async {
        guard project.isXcode else { return }  // Flutter/Android don't use Xcode schemes
        if !force, schemes[project.id] != nil { return }
        guard !loadingSchemes.contains(project.id) else { return }
        loadingSchemes.insert(project.id)
        defer { loadingSchemes.remove(project.id) }

        do {
            let result = try await Shell.run(
                Shell.xcrunPath,
                ["xcodebuild", "-list", "-json", project.containerFlag, project.url.path],
                currentDirectory: project.directory
            )
            let list: [String]
            do {
                list = try Self.parseSchemes(result.stdout)
            } catch {
                throw ShellError.failed(command: "xcodebuild -list", status: result.status, output: result.stderr)
            }
            schemes[project.id] = list
            schemeErrors[project.id] = list.isEmpty ? "No shared schemes found. Open the project in Xcode once, or share a scheme." : nil

            if let current = chosenSchemes[project.id], list.contains(current) { return }
            setScheme(Self.preferredScheme(in: list, for: project), for: project)
        } catch {
            schemeErrors[project.id] = error.localizedDescription
        }
    }

    private struct XcodeList: Decodable {
        struct Container: Decodable { let schemes: [String]? }
        let project: Container?
        let workspace: Container?
    }

    nonisolated static func parseSchemes(_ output: String) throws -> [String] {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let list = try JSONDecoder().decode(XcodeList.self, from: Data(output[start...end].utf8))
        return list.workspace?.schemes ?? list.project?.schemes ?? []
    }

    nonisolated private static func preferredScheme(in schemes: [String], for project: XcodeProject) -> String? {
        if let exact = schemes.first(where: { $0 == project.name }) { return exact }
        // Skip CocoaPods / dependency schemes when guessing.
        return schemes.first(where: { !$0.hasPrefix("Pods") }) ?? schemes.first
    }
}

/// Walks tracked folders looking for Xcode workspaces/projects, Flutter apps and Android (Gradle) apps.
enum ProjectScanner {
    private static let skippedDirectories: Set<String> = [
        "Pods", "Carthage", "node_modules", "DerivedData", "build", "Build",
        "SourcePackages", "vendor", "fastlane", "xcuserdata",
    ]

    static func scan(_ roots: [URL], maxDepth: Int = 5) -> [XcodeProject] {
        var seen = Set<String>()
        var results: [XcodeProject] = []
        for root in roots {
            for project in scan(root: root, maxDepth: maxDepth) where seen.insert(project.id).inserted {
                results.append(project)
            }
        }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func scan(root: URL, maxDepth: Int) -> [XcodeProject] {
        if let project = project(at: root) { return [project] }
        var found: [XcodeProject] = []
        walk(root, depth: 0, maxDepth: maxDepth, into: &found)
        return found
    }

    private static func project(at url: URL) -> XcodeProject? {
        switch url.pathExtension {
        case "xcworkspace": return XcodeProject(url: url, kind: .workspace)
        case "xcodeproj": return XcodeProject(url: url, kind: .project)
        default: return nil
        }
    }

    private static func walk(_ directory: URL, depth: Int, maxDepth: Int, into found: inout [XcodeProject]) {
        guard depth <= maxDepth else { return }

        // Flutter app: its ios/ and android/ folders belong to it, so don't list them separately.
        if isFlutterApp(directory) {
            found.append(XcodeProject(url: directory, kind: .flutter))
            return
        }
        // Android app. Keep walking afterwards so e.g. a Kotlin Multiplatform iosApp/ is found too.
        let androidModule = androidAppModule(in: directory)
        if let androidModule {
            found.append(XcodeProject(url: directory, kind: .android, androidModule: androidModule))
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        var workspaces: [URL] = []
        var projects: [URL] = []
        var subdirectories: [URL] = []

        for url in entries {
            switch url.pathExtension {
            case "xcworkspace": workspaces.append(url)
            case "xcodeproj": projects.append(url)
            default:
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true, values?.isSymbolicLink != true,
                   !skippedDirectories.contains(url.lastPathComponent) {
                    subdirectories.append(url)
                }
            }
        }

        // A workspace next to a project (CocoaPods, multi-project setups) already contains it.
        if !workspaces.isEmpty {
            found += workspaces.map { XcodeProject(url: $0, kind: .workspace) }
            return
        }
        if !projects.isEmpty {
            found += projects.map { XcodeProject(url: $0, kind: .project) }
            return
        }
        for subdirectory in subdirectories {
            // Gradle modules of an Android app can't be apps themselves.
            if let androidModule,
               subdirectory.lastPathComponent == androidModule || androidModuleNames.contains(subdirectory.lastPathComponent) {
                continue
            }
            walk(subdirectory, depth: depth + 1, maxDepth: maxDepth, into: &found)
        }
    }

    private static let androidModuleNames: Set<String> = ["gradle", "buildSrc"]

    // MARK: - Flutter / Android detection

    /// A Flutter *app* (not a package/plugin): pubspec.yaml depends on the Flutter SDK and lib/main.dart exists.
    static func isFlutterApp(_ directory: URL) -> Bool {
        let pubspec = directory.appendingPathComponent("pubspec.yaml")
        guard let text = try? String(contentsOf: pubspec, encoding: .utf8),
              text.contains("sdk: flutter") else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("lib/main.dart").path)
    }

    /// Returns the Gradle module that applies the Android application plugin, if `directory` is a Gradle root.
    static func androidAppModule(in directory: URL) -> String? {
        let fm = FileManager.default
        let isGradleRoot = ["settings.gradle", "settings.gradle.kts"]
            .contains { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
        guard isGradleRoot,
              let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return nil }
        var modules: [String] = []
        for child in children {
            for file in ["build.gradle.kts", "build.gradle"] {
                guard let text = try? String(contentsOf: child.appendingPathComponent(file), encoding: .utf8) else { continue }
                if appliesAndroidApplication(text) {
                    modules.append(child.lastPathComponent)
                    break
                }
            }
        }
        if modules.contains("app") { return "app" }
        return modules.sorted().first
    }

    private static func appliesAndroidApplication(_ buildScript: String) -> Bool {
        buildScript.contains("com.android.application")        // plugins { id("com.android.application") } / apply plugin
            || buildScript.contains("plugins.android.application") // version catalog: alias(libs.plugins.android.application)
            || buildScript.contains("plugins.androidApplication")  // KMP templates: alias(libs.plugins.androidApplication)
    }
}
