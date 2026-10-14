import AppKit
import SwiftUI

// MARK: - Detection and commands

/// Web apps run with a dev server command: package.json scripts (npm, pnpm, yarn, bun),
/// Django (manage.py), Rails (bin/rails) or Laravel (artisan).
enum WebProject {
    enum Manager: String {
        case npm, pnpm, yarn, bun

        /// Command that runs a package.json script.
        func run(_ script: String) -> String {
            switch self {
            case .npm: return script == "start" ? "npm start" : "npm run \(script)"
            case .pnpm: return "pnpm \(script)"
            case .yarn: return "yarn \(script)"
            case .bun: return "bun run \(script)"
            }
        }

        var install: String {
            switch self {
            case .npm: return "npm install"
            case .pnpm: return "pnpm install"
            case .yarn: return "yarn install"
            case .bun: return "bun install"
            }
        }
    }

    /// Scripts that start a dev server, best first.
    private static let devScripts = ["dev", "start", "serve", "develop"]

    /// Whether `directory` is a web app worth listing.
    static func isWebApp(_ directory: URL) -> Bool {
        if let package = packageJSON(in: directory) {
            let scripts = package["scripts"] as? [String: Any] ?? [:]
            guard devScripts.contains(where: { scripts[$0] != nil }) else { return false }
            // React Native apps run on devices (their ios/ and android/ folders are found separately).
            let dependencies = (package["dependencies"] as? [String: Any] ?? [:])
                .merging(package["devDependencies"] as? [String: Any] ?? [:]) { first, _ in first }
            if dependencies["react-native"] != nil, dependencies["react-native-web"] == nil {
                return false
            }
            return true
        }
        return nonNodeCommand(in: directory) != nil
    }

    static func manager(in directory: URL) -> Manager {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: directory.appendingPathComponent(name).path) }
        if has("pnpm-lock.yaml") { return .pnpm }
        if has("yarn.lock") { return .yarn }
        if has("bun.lockb") || has("bun.lock") { return .bun }
        // package.json "packageManager": "pnpm@9.0.0"
        if let field = packageJSON(in: directory)?["packageManager"] as? String,
           let name = field.split(separator: "@").first, let manager = Manager(rawValue: String(name)) {
            return manager
        }
        return .npm
    }

    struct Script: Hashable {
        let name: String
        let command: String
    }

    /// package.json scripts, sorted by name.
    static func scripts(in directory: URL) -> [Script] {
        let scripts = packageJSON(in: directory)?["scripts"] as? [String: Any] ?? [:]
        return scripts.compactMap { key, value in (value as? String).map { Script(name: key, command: $0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The recognised dev server command, e.g. "pnpm dev" or "python3 manage.py runserver" ("" if none).
    static func defaultCommand(in directory: URL) -> String {
        let key = directory.path
        let stamp = modificationStamp(directory)
        if let cached = cache[key], cached.stamp == stamp { return cached.command }
        var command = ""
        if let package = packageJSON(in: directory) {
            let scripts = package["scripts"] as? [String: Any] ?? [:]
            if let script = devScripts.first(where: { scripts[$0] != nil }) {
                command = manager(in: directory).run(script)
            }
        } else if let other = nonNodeCommand(in: directory) {
            command = other
        }
        cache[key] = (stamp, command)
        return command
    }

    /// The command Run uses: the custom one from Run Options, or the detected one.
    static func command(for project: XcodeProject, options: RunOptions) -> String {
        let custom = options.webCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? defaultCommand(in: project.directory) : custom
    }

    private static func nonNodeCommand(in directory: URL) -> String? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: directory.appendingPathComponent(name).path) }
        if has("manage.py") { return "python3 manage.py runserver" }
        if has("bin/rails") { return "bin/rails server" }
        if has("artisan") { return "php artisan serve" }
        return nil
    }

    private static func packageJSON(in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    // The popup redraws often while logs stream; don't re-read package.json unless it changed.
    private static var cache: [String: (stamp: Date?, command: String)] = [:]

    private static func modificationStamp(_ directory: URL) -> Date? {
        let file = directory.appendingPathComponent("package.json").path
        return (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
    }

    /// First http(s) URL in a dev server's output, e.g. "Local: http://localhost:5173/".
    static func url(in line: String) -> URL? {
        let pattern = #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|[A-Za-z0-9.-]+):\d{2,5}[^\s'"]*"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        var text = String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]"))
        // 0.0.0.0 / [::] mean "all interfaces"; the browser needs localhost.
        text = text.replacingOccurrences(of: "://0.0.0.0", with: "://localhost")
            .replacingOccurrences(of: "://[::]", with: "://localhost")
            .replacingOccurrences(of: "://[::1]", with: "://localhost")
        return URL(string: text)
    }
}

// MARK: - Stopping a dev server

/// A dev server is a tree (sh → npm → node → esbuild…). Stopping only the top process can leave
/// the server running and its port taken, so the whole tree is signalled.
enum ProcessTree {
    static func descendants(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var queue = [pid]
        while let current = queue.popLast() {
            for child in children(of: current) where !result.contains(child) {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    private static func children(of pid: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    private static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// SIGINT (like Ctrl-C) to the whole tree, then SIGTERM and SIGKILL to anything still running.
    static func terminate(_ pid: Int32) {
        DispatchQueue.global(qos: .userInitiated).async {
            var all = Set([pid] + descendants(of: pid))
            for sig in [SIGINT, SIGTERM, SIGKILL] {
                for member in Array(all) where isAlive(member) {
                    all.formUnion(descendants(of: member))
                }
                let alive = all.filter(isAlive)
                if alive.isEmpty { return }
                for member in alive { kill(member, sig) }
                Thread.sleep(forTimeInterval: sig == SIGKILL ? 0 : 3)
            }
        }
    }

    /// Immediate SIGTERM to the tree (used when the app quits).
    static func terminateNow(_ pid: Int32) {
        for member in [pid] + descendants(of: pid) { kill(member, SIGTERM) }
    }
}

// MARK: - Popup rows

/// Replaces the device row for web projects: the dev server's state and URL, with Open.
struct WebServerRow: View {
    let project: XcodeProject
    @EnvironmentObject private var runner: BuildRunner

    private var session: RunSession? { runner.session(for: project.id) }
    private var url: URL? { session?.webURL }
    private var isRunning: Bool { session?.isRunning ?? false }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "globe")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                Circle()
                    .fill(url != nil ? Color.green : (isRunning ? Color.orange : Color.secondary.opacity(0.6)))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(url?.absoluteString ?? "Local dev server")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open", systemImage: "safari")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open \(url.absoluteString) in your browser")
            }
        }
        .listRow()
    }

    private var subtitle: String {
        if url != nil { return "\(project.name) · running" }
        if isRunning { return "\(project.name) · starting…" }
        return "\(project.name) · not running"
    }
}

/// Dev server command above the Run button: prefilled with the detected one, editable per project.
struct WebCommandField: View {
    let project: XcodeProject
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var runner: BuildRunner

    @State private var detected = ""
    @State private var scripts: [WebProject.Script] = []

    private var isRunning: Bool { runner.session(for: project.id)?.isRunning ?? false }
    private var custom: String { projects.runOptions(for: project).webCommand }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .help("Command that starts the dev server (runs in the project folder)")
            TextField(detected.isEmpty ? "Command to start the dev server" : detected, text: Binding(
                get: { custom.isEmpty ? detected : custom },
                set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    projects.updateRunOptions(for: project) { $0.webCommand = trimmed == detected ? "" : value }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.callout, design: .monospaced))

            if !custom.isEmpty && !detected.isEmpty {
                Button {
                    projects.updateRunOptions(for: project) { $0.webCommand = "" }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Use the detected command: \(detected)")
            }

            if !scripts.isEmpty {
                let manager = WebProject.manager(in: project.directory)
                Menu {
                    Section("package.json scripts") {
                        ForEach(scripts, id: \.name) { script in
                            Button("\(script.name)  —  \(script.command)") {
                                let command = manager.run(script.name)
                                projects.updateRunOptions(for: project) {
                                    $0.webCommand = command == detected ? "" : command
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pick a package.json script")
            }
        }
        .disabled(isRunning)
        .task(id: project.id) {
            detected = WebProject.defaultCommand(in: project.directory)
            scripts = WebProject.scripts(in: project.directory)
        }
    }
}
