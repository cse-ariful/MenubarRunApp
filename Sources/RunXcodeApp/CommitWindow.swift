import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted with the repository root URL as `object` after a commit, so status rows refresh.
    static let gitRepositoryChanged = Notification.Name("RunXcodeApp.gitRepositoryChanged")
}

/// One commit window per repository; opening it again brings the existing one to the front.
enum CommitWindow {
    private static var controllers: [URL: NSWindowController] = [:]
    private static var observers: [URL: NSObjectProtocol] = [:]

    static func show(root: URL, branch: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = controllers[root] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Commit — \(root.lastPathComponent) (\(branch))"
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CommitView(root: root, branch: branch) { [weak window] in
            window?.close()
        })
        window.center()

        let controller = NSWindowController(window: window)
        controllers[root] = controller
        observers[root] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            controllers[root] = nil
            if let token = observers.removeValue(forKey: root) {
                NotificationCenter.default.removeObserver(token)
            }
        }
        DockPresence.track(window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

/// File list with checkboxes on the left, the selected file's diff on the right,
/// and the commit message with a Commit button at the bottom.
private struct CommitView: View {
    let root: URL
    let branch: String
    let close: () -> Void

    @State private var changes: [GitChange] = []
    @State private var selected: Set<String> = []
    @State private var focused: GitChange.ID? = nil
    @State private var diff = ""
    @State private var message = ""
    @State private var loading = true
    @State private var committing = false
    @State private var error: String? = nil
    /// "Committing…" / "Pushing to origin/main…" while working.
    @State private var progress: String? = nil
    /// Where Commit & Push goes, e.g. "origin/main" (nil when detached or not a branch).
    @State private var pushTarget: String? = nil
    @State private var hasUpstream = true

    private var selectedChanges: [GitChange] { changes.filter { selected.contains($0.id) } }
    private var canCommit: Bool {
        !committing && !selected.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                fileList
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                diffView
                    .frame(minWidth: 320)
            }
            Divider()
            footer
        }
        .task { await reload() }
        .onChange(of: focused) { _ in Task { await loadDiff() } }
    }

    // MARK: Files

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { !changes.isEmpty && selected.count == changes.count },
                    set: { all in selected = all ? Set(changes.map(\.id)) : [] }
                )) {
                    Text("\(selected.count) of \(changes.count) selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .disabled(changes.isEmpty)
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload changes")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()

            if loading && changes.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if changes.isEmpty {
                Text("No changes to commit.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $focused) {
                    ForEach(changes) { change in
                        fileRow(change).tag(change.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func fileRow(_ change: GitChange) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { selected.contains(change.id) },
                set: { on in
                    if on { selected.insert(change.id) } else { selected.remove(change.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Text(change.badge)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(badgeColor(change.badge))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(change.fileName)
                    .lineLimit(1)
                    .strikethrough(change.badge == "D")
                if !change.folder.isEmpty {
                    Text(change.folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .help(change.path)
    }

    private func badgeColor(_ badge: String) -> Color {
        switch badge {
        case "A", "?": return .green
        case "D": return .red
        case "U": return .orange
        default: return .blue
        }
    }

    // MARK: Diff

    private var diffView: some View {
        Group {
            if focused == nil {
                Text(changes.isEmpty ? "" : "Select a file to see its changes.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Lines never wrap (scroll sideways for long ones); every row is at least as wide
                // as the pane so the +/- highlight spans the full width.
                GeometryReader { geometry in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(lineColor(line))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 8)
                                    .frame(minWidth: geometry.size.width, alignment: .leading)
                                    .background(lineBackground(line))
                            }
                        }
                        .padding(.vertical, 6)
                        .textSelection(.enabled)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    /// Long diffs are capped so the window stays responsive.
    private var diffLines: [String] {
        let all = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard all.count > 4000 else { return all }
        return Array(all.prefix(4000)) + ["… \(all.count - 4000) more lines not shown"]
    }

    private func isHeader(_ line: String) -> Bool {
        line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("+++") || line.hasPrefix("---")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
    }

    private func lineColor(_ line: String) -> Color {
        if isHeader(line) { return .secondary }
        if line.hasPrefix("@@") { return .purple }
        return .primary
    }

    private func lineBackground(_ line: String) -> Color {
        if isHeader(line) { return .clear }
        if line.hasPrefix("+") { return Color.green.opacity(0.15) }
        if line.hasPrefix("-") { return Color.red.opacity(0.15) }
        return .clear
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $message)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                if message.isEmpty {
                    Text("Commit message (first line is the summary)")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 10) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } else if let progress {
                    Text(progress)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Commits only the checked files to \(branch).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if committing { ProgressView().controlSize(.small) }
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Commit & Push") {
                    commit(push: true)
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!canCommit || pushTarget == nil)
                .help(pushTarget.map { "Commit, then push to \($0)" + (hasUpstream ? "" : " (sets the upstream)") + " (⇧⌘↩)" }
                      ?? "Can't push from a detached HEAD")
                Button(selected.count == 1 ? "Commit 1 File" : "Commit \(selected.count) Files") {
                    commit(push: false)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canCommit)
                .help("⌘↩")
            }
        }
        .padding(12)
    }

    // MARK: Actions

    private func reload() async {
        loading = true
        if let status = await Git.status(for: root), !status.isDetached {
            pushTarget = Git.pushTarget(status)
            hasUpstream = status.upstream != nil
        } else {
            pushTarget = nil
        }
        do {
            let fresh = try await Git.changes(in: root)
            let known = Set(changes.map(\.id))
            // Keep previous choices; newly appeared files start checked (everything on first load).
            selected = Set(fresh.map(\.id).filter { selected.contains($0) || !known.contains($0) })
            changes = fresh
            if focused == nil || !fresh.contains(where: { $0.id == focused }) {
                focused = fresh.first?.id
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
        await loadDiff()
    }

    private func loadDiff() async {
        guard let id = focused, let change = changes.first(where: { $0.id == id }) else {
            diff = ""
            return
        }
        let text = await Git.diff(of: change, in: root)
        if focused == id { diff = text }
    }

    /// Commits the checked files; with `push`, pushes the branch afterwards
    /// (`git push`, or `git push -u <remote> <branch>` the first time).
    private func commit(push: Bool) {
        guard canCommit else { return }
        committing = true
        error = nil
        progress = "Committing…"
        let picked = selectedChanges
        Task {
            do {
                try await Git.commit(picked, message: message, in: root)
            } catch {
                self.error = error.localizedDescription
                committing = false
                progress = nil
                await reload()
                return
            }

            if push {
                do {
                    guard let status = await Git.status(for: root) else {
                        throw GitError.failed(command: "status", output: "Couldn't read the repository.")
                    }
                    progress = "Pushing to \(Git.pushTarget(status))…"
                    try await Git.push(status)
                } catch {
                    // The commit is made; keep the window open with the push error.
                    NotificationCenter.default.post(name: .gitRepositoryChanged, object: root)
                    self.error = "Committed, but the push failed: \(error.localizedDescription)"
                    committing = false
                    progress = nil
                    message = ""
                    await reload()
                    return
                }
            }

            NotificationCenter.default.post(name: .gitRepositoryChanged, object: root, userInfo: ["pushed": push])
            committing = false
            progress = nil
            close()
        }
    }
}
