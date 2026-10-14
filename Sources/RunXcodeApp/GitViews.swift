import AppKit
import SwiftUI

// MARK: - Model

/// Git state for the selected project, shared by the branch row (main view) and the git page.
@MainActor
final class GitModel: ObservableObject {
    @Published private(set) var status: GitStatus? = nil
    /// False until the first status read for the current project finishes.
    @Published private(set) var loaded = false
    @Published private(set) var busy: String? = nil
    @Published var message: String? = nil
    @Published private(set) var messageIsError = false
    /// Set while the push confirmation is showing.
    @Published var pushPreview: PushPreview? = nil
    @Published var isCreatingBranch = false
    @Published var newBranchName = ""

    private var directory: URL?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .gitRepositoryChanged, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let root = note.object as? URL, root == self.status?.root else { return }
                self.show("Committed to \(self.status?.branch ?? "branch").", error: false)
                await self.refresh()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Switches to another project's repository (or none).
    func load(_ project: XcodeProject?) async {
        let target = project?.directory
        guard target != directory || !loaded else { return }
        directory = target
        status = nil
        loaded = false
        busy = nil
        message = nil
        pushPreview = nil
        isCreatingBranch = false
        await refresh()
        if directory == target { loaded = true }
    }

    func refresh() async {
        guard let directory else {
            status = nil
            return
        }
        let fresh = await Git.status(for: directory)
        if directory == self.directory { status = fresh }  // ignore results for a project we've left
    }

    /// Refresh with the busy indicator (for the Refresh button).
    func reload() {
        guard busy == nil else { return }
        busy = "Reading branch, changes and remotes…"
        Task {
            await refresh()
            busy = nil
        }
    }

    func clearTransient() {
        message = nil
        pushPreview = nil
        isCreatingBranch = false
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    func perform(_ label: String, success: String, _ operation: @escaping () async throws -> Void) {
        guard busy == nil else { return }
        busy = label
        message = nil
        Task {
            do {
                try await operation()
                show(success, error: false)
            } catch {
                show(error.localizedDescription, error: true)
            }
            busy = nil
            await refresh()
        }
    }

    // MARK: Actions

    func pull() {
        guard let status else { return }
        perform("Pulling…", success: "Pulled \(status.branch).") { try await Git.pull(status) }
    }

    func fetch() {
        guard let status else { return }
        perform("Fetching…", success: "Fetched.") { try await Git.fetch(status) }
    }

    func switchTo(_ branch: String) {
        guard let status, branch != status.branch else { return }
        perform("Switching to \(branch)…", success: "Switched to \(branch).") { try await Git.switchTo(branch, in: status) }
    }

    func checkoutRemote(_ name: String) {
        guard let status else { return }
        perform("Checking out \(name)…", success: "Switched to \(name).") { try await Git.checkoutRemote(name, in: status) }
    }

    func beginNewBranch() {
        newBranchName = ""
        pushPreview = nil
        isCreatingBranch = true
    }

    func createBranch() {
        guard let status else { return }
        let name = newBranchName
        isCreatingBranch = false
        perform("Creating branch…", success: "Created and switched to \(name.trimmingCharacters(in: .whitespaces)).") {
            try await Git.createBranch(name, in: status)
        }
    }

    func openCommitWindow() {
        guard let status else { return }
        CommitWindow.show(root: status.root, branch: status.isDetached ? "detached HEAD" : status.branch)
    }

    /// Loads the outgoing commits, then shows the confirmation.
    func confirmPush() {
        guard let status, busy == nil else { return }
        busy = "Checking what to push…"
        message = nil
        isCreatingBranch = false
        Task {
            let outgoing = await Git.outgoing(status)
            busy = nil
            if outgoing.count == 0, let upstream = status.upstream {
                show("Nothing to push: \(status.branch) is up to date with \(upstream).", error: false)
                return
            }
            withAnimation {
                pushPreview = PushPreview(target: Git.pushTarget(status), count: outgoing.count,
                                          subjects: outgoing.subjects, isPublish: status.upstream == nil)
            }
        }
    }

    func push() {
        guard let status, let preview = pushPreview else { return }
        pushPreview = nil
        perform("Pushing…", success: "Pushed \(status.branch) to \(preview.target).") { try await Git.push(status) }
    }

    // MARK: Text

    var syncSummary: String {
        guard let status else { return "" }
        var parts: [String] = []
        if let upstream = status.upstream {
            parts.append(status.ahead == 0 && status.behind == 0 ? "up to date with \(upstream)" : "↑\(status.ahead) ↓\(status.behind)")
        } else if !status.isDetached {
            parts.append("not pushed yet")
        }
        if status.changes > 0 { parts.append("\(status.changes) changed") }
        return parts.joined(separator: " · ")
    }
}

/// What a push would send, for the confirmation.
struct PushPreview: Equatable {
    let target: String
    let count: Int
    let subjects: [String]
    /// The branch has no upstream yet; the push creates it.
    let isPublish: Bool

    var title: String {
        let commits = count == 1 ? "1 commit" : "\(count) commits"
        return isPublish ? "Publish branch to \(target)?" + (count > 0 ? " (\(commits))" : "")
                         : "Push \(commits) to \(target)?"
    }
}

// MARK: - Branch row (main view and page header)

/// Full-width branch row. In the main view it opens the git page; as the page header it closes it.
struct GitBranchRow: View {
    @EnvironmentObject private var git: GitModel
    var isOpen = false
    let action: () -> Void

    var body: some View {
        Group {
            if let status = git.status {
                Button(action: action) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(status.isDetached ? "detached HEAD" : status.branch)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            Text(git.busy ?? git.syncSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 4)
                        if git.busy != nil {
                            ProgressView().controlSize(.small)
                        }
                        DrillChevron(isOpen: isOpen)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRow()
                .help(isOpen ? "Back" : "Git: pull, push, fetch, commit, branches")
            } else {
                placeholder
            }
        }
        .popupMatched("git")
    }

    /// Same height as the branch row, so nothing jumps when the status arrives.
    private var placeholder: some View {
        HStack(spacing: 10) {
            Group {
                if git.loaded {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(git.loaded ? "No git repository" : "Git")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(git.loaded ? .secondary : .primary)
                Text(git.loaded ? "This project folder isn't tracked by git." : "Reading branch, changes and remotes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .listRow()
    }
}

/// Branch row plus the Commit button and the last message, for the main view.
struct GitSummary: View {
    @EnvironmentObject private var git: GitModel
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GitBranchRow(action: open)
            if let status = git.status, status.changes > 0 {
                ActionTile(
                    title: status.changes == 1 ? "Commit 1 Change…" : "Commit \(status.changes) Changes…",
                    systemImage: "checkmark.circle",
                    disabled: git.busy != nil
                ) { git.openCommitWindow() }
                .padding(.horizontal, 8)
            }
            if let message = git.message {
                MessageBanner(text: message, isError: git.messageIsError, onDismiss: {
                    withAnimation { git.message = nil }
                })
            }
            Divider()
        }
    }
}

// MARK: - Git page

/// The git page: branch row on top, actions, then searchable local and remote branches.
struct GitPage: View {
    @EnvironmentObject private var git: GitModel
    let close: () -> Void

    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GitBranchRow(isOpen: true, action: close)

            if let status = git.status {
                actions(status)
                    .padding(.horizontal, 8)

                if let preview = git.pushPreview {
                    pushConfirmation(preview)
                }
                if git.isCreatingBranch {
                    newBranchField(status)
                }
                if let message = git.message {
                    MessageBanner(text: message, isError: git.messageIsError, onDismiss: {
                        withAnimation { git.message = nil }
                    })
                }

                SearchField(text: $search, prompt: "Search branches")
                    .padding(.horizontal, 8)

                ScrollView {
                    branchList(status)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: Actions

    private func actions(_ status: GitStatus) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
        let idle = git.busy == nil
        return LazyVGrid(columns: columns, spacing: 6) {
            ActionTile(title: status.behind > 0 ? "Pull ↓\(status.behind)" : "Pull", systemImage: "arrow.down.to.line",
                       disabled: !idle || status.upstream == nil || status.isDetached) { git.pull() }
                .help(status.upstream == nil ? "No upstream branch to pull from" : "git pull --ff-only")
            ActionTile(title: status.ahead > 0 ? "Push ↑\(status.ahead)" : "Push", systemImage: "arrow.up.to.line",
                       disabled: !idle || status.isDetached) { git.confirmPush() }
                .help(status.upstream == nil ? "Publish this branch (asks first)" : "git push (asks first)")
            ActionTile(title: "Fetch", systemImage: "arrow.down.circle", disabled: !idle) { git.fetch() }
                .help("git fetch --all --prune")
            ActionTile(title: status.changes > 0 ? "Commit (\(status.changes))" : "Commit", systemImage: "checkmark.circle",
                       disabled: !idle || status.changes == 0) { git.openCommitWindow() }
                .help("Choose files and commit them")
            ActionTile(title: "New Branch", systemImage: "plus", disabled: !idle) {
                withAnimation { git.beginNewBranch() }
            }
            .help("Create a branch from the current one and switch to it")
            ActionTile(title: "Refresh", systemImage: "arrow.clockwise", disabled: !idle) { git.reload() }
        }
    }

    private func newBranchField(_ status: GitStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("new-branch-name", text: $git.newBranchName)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit { git.createBranch() }
                Button("Create") { git.createBranch() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(git.newBranchName.trimmingCharacters(in: .whitespaces).isEmpty || git.busy != nil)
                Button {
                    withAnimation { git.isCreatingBranch = false }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Cancel")
            }
            Text("Creates the branch from \(status.isDetached ? "HEAD" : status.branch) and switches to it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    /// Inline "Push N commits to origin/main?" with the commit list, Cancel and Push.
    private func pushConfirmation(_ preview: PushPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(preview.title, systemImage: "arrow.up.circle.fill")
                .font(.callout.weight(.semibold))
            if preview.subjects.isEmpty {
                Text(preview.isPublish ? "No new commits; this creates the branch on the remote." : "Nothing new to push.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(preview.subjects.prefix(5), id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if preview.count > 5 {
                        Text("and \(preview.count - 5) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { withAnimation { git.pushPreview = nil } }
                    .controlSize(.small)
                Button("Push") { git.push() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
        .padding(.horizontal, 8)
    }

    // MARK: Branches

    private func matches(_ name: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    @ViewBuilder
    private func branchList(_ status: GitStatus) -> some View {
        let local = status.localBranches.filter(matches)
        let remote = status.remoteBranches.filter(matches)
        let grouped = Dictionary(grouping: remote) { String($0.split(separator: "/").first ?? "") }

        VStack(alignment: .leading, spacing: 2) {
            if local.isEmpty && remote.isEmpty {
                Text(search.isEmpty ? "No branches." : "No branches match “\(search)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }

            if !local.isEmpty {
                PageSectionTitle(title: "Local Branches", count: local.count)
                ForEach(local, id: \.self) { branch in
                    let isCurrent = branch == status.branch
                    BranchListRow(name: branch, isCurrent: isCurrent, symbol: "arrow.triangle.branch",
                                  disabled: git.busy != nil || isCurrent) {
                        git.switchTo(branch)
                    }
                    .help(isCurrent ? "Current branch" : "Switch to \(branch)")
                }
            }

            ForEach(grouped.keys.sorted(), id: \.self) { remoteName in
                PageSectionTitle(title: grouped.count > 1 ? "Remote Branches · \(remoteName)" : "Remote Branches",
                                 count: grouped[remoteName]?.count ?? 0)
                ForEach(grouped[remoteName] ?? [], id: \.self) { name in
                    BranchListRow(name: name, isCurrent: false, symbol: "network", disabled: git.busy != nil) {
                        git.checkoutRemote(name)
                    }
                    .help("Check out \(name) as a local branch")
                }
            }
        }
        .padding(.bottom, 4)
    }
}

private struct BranchListRow: View {
    let name: String
    let isCurrent: Bool
    let symbol: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                Text(name)
                    .font(isCurrent ? .body.weight(.semibold) : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled && !isCurrent)
        .compactListRow()
    }
}
