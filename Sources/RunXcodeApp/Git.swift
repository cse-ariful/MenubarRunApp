import Foundation

/// Snapshot of a project's git repository.
struct GitStatus: Equatable {
    let root: URL
    /// Current branch name, or "HEAD" when detached.
    let branch: String
    /// e.g. "origin/main"; nil when the branch has no upstream yet.
    let upstream: String?
    let ahead: Int
    let behind: Int
    /// Number of changed / untracked files.
    let changes: Int
    let localBranches: [String]
    /// Remote branches without a local branch of the same name, e.g. "origin/feature-x".
    let remoteBranches: [String]
    let remotes: [String]

    var isDetached: Bool { branch == "HEAD" }
}

enum GitError: LocalizedError {
    case failed(command: String, output: String)
    case invalidBranchName(String)
    case emptyMessage
    case nothingSelected

    var errorDescription: String? {
        switch self {
        case let .failed(command, output):
            return "git \(command) failed" + (output.isEmpty ? "." : ": \(output)")
        case let .invalidBranchName(name):
            return "“\(name)” isn't a valid branch name."
        case .emptyMessage:
            return "Enter a commit message."
        case .nothingSelected:
            return "Select at least one file to commit."
        }
    }
}

/// Runs the user's `git` (Xcode Command Line Tools or Homebrew) against a project's repository.
enum Git {
    static var path: String { Shell.which("git") ?? "/usr/bin/git" }

    /// Never block on an interactive prompt: fail with a message instead.
    private static let environment: [String: String] = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_SSH_COMMAND": "ssh -o BatchMode=yes",
        "LC_ALL": "C",
    ]

    @discardableResult
    private static func run(_ arguments: [String], in directory: URL, trim: Bool = true,
                            extraEnvironment: [String: String] = [:]) async throws -> String {
        let env = environment.merging(extraEnvironment) { $1 }
        let result = try await Shell.run(path, ["-C", directory.path] + arguments, environment: env)
        guard result.succeeded else {
            let output = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("hint:") }
                .suffix(3)
                .joined(separator: " ")
            throw GitError.failed(command: arguments.first ?? "", output: output)
        }
        return trim ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : result.stdout
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    /// nil when `directory` isn't inside a git repository.
    static func status(for directory: URL) async -> GitStatus? {
        guard let rootPath = try? await run(["rev-parse", "--show-toplevel"], in: directory) else { return nil }
        let root = URL(fileURLWithPath: rootPath)

        let branch = (try? await run(["rev-parse", "--abbrev-ref", "HEAD"], in: root)) ?? "HEAD"
        let upstream = try? await run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: root)

        var ahead = 0, behind = 0
        if upstream != nil, let counts = try? await run(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: root) {
            let parts = counts.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
            if parts.count == 2 { behind = parts[0]; ahead = parts[1] }
        }

        let changes = lines((try? await run(["status", "--porcelain"], in: root)) ?? "").count
        let local = lines((try? await run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: root)) ?? "")
        let remotes = lines((try? await run(["remote"], in: root)) ?? "")
        let localSet = Set(local)
        let remote = lines((try? await run(["for-each-ref", "--format=%(refname:short)", "refs/remotes"], in: root)) ?? "")
            .filter { !$0.hasSuffix("/HEAD") && $0.contains("/") }
            .filter { name in
                let short = String(name[name.index(after: name.firstIndex(of: "/")!)...])
                return !localSet.contains(short)
            }

        return GitStatus(root: root, branch: branch, upstream: upstream, ahead: ahead, behind: behind,
                         changes: changes, localBranches: local, remoteBranches: remote, remotes: remotes)
    }

    // MARK: - Actions

    static func fetch(_ status: GitStatus) async throws {
        try await run(["fetch", "--all", "--prune"], in: status.root)
    }

    /// Fast-forward only, so a pull never creates a surprise merge commit.
    static func pull(_ status: GitStatus) async throws {
        try await run(["pull", "--ff-only"], in: status.root)
    }

    /// Pushes the current branch; sets the upstream on the first push.
    static func push(_ status: GitStatus) async throws {
        if status.upstream != nil {
            try await run(["push"], in: status.root)
        } else {
            let remote = status.remotes.contains("origin") ? "origin" : (status.remotes.first ?? "origin")
            try await run(["push", "-u", remote, status.branch], in: status.root)
        }
    }

    static func switchTo(_ branch: String, in status: GitStatus) async throws {
        try await run(["switch", branch], in: status.root)
    }

    /// Creates a local branch tracking `remoteBranch` (e.g. "origin/feature") and switches to it.
    static func checkoutRemote(_ remoteBranch: String, in status: GitStatus) async throws {
        try await run(["switch", "--track", remoteBranch], in: status.root)
    }

    /// Creates `name` from the current branch and switches to it.
    static func createBranch(_ name: String, in status: GitStatus) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? await run(["check-ref-format", "--branch", trimmed], in: status.root)) != nil else {
            throw GitError.invalidBranchName(trimmed)
        }
        try await run(["switch", "-c", trimmed], in: status.root)
    }

    // MARK: - Push preview

    /// Commits a push would send: everything ahead of the upstream, or (no upstream yet)
    /// everything not on any remote. `subjects` holds at most `limit` one-line summaries.
    static func outgoing(_ status: GitStatus, limit: Int = 20) async -> (count: Int, subjects: [String]) {
        let range = status.upstream != nil ? ["@{u}..HEAD"] : ["HEAD", "--not", "--remotes"]
        let count = Int((try? await run(["rev-list", "--count"] + range, in: status.root)) ?? "") ?? 0
        let log = (try? await run(["log", "--no-color", "--no-decorate", "--format=%h %s", "-n", "\(limit)"] + range,
                                  in: status.root)) ?? ""
        return (count, lines(log))
    }

    /// Where a push goes, e.g. "origin/main".
    static func pushTarget(_ status: GitStatus) -> String {
        if let upstream = status.upstream { return upstream }
        let remote = status.remotes.contains("origin") ? "origin" : (status.remotes.first ?? "origin")
        return "\(remote)/\(status.branch)"
    }

    // MARK: - Commit

    /// Paths are matched literally (no glob or `:(magic)` interpretation).
    private static let literalPaths = ["GIT_LITERAL_PATHSPECS": "1"]

    /// Pending changes, one entry per file (renames are listed as a delete plus an add).
    static func changes(in root: URL) async throws -> [GitChange] {
        let output = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"],
                                   in: root, trim: false)
        return output.split(separator: "\0").compactMap { entry -> GitChange? in
            let chars = Array(entry)
            guard chars.count > 3 else { return nil }
            return GitChange(path: String(chars[3...]), index: chars[0], worktree: chars[1])
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Diff of one file against HEAD (staged and unstaged together); new files are shown in full.
    static func diff(of change: GitChange, in root: URL) async -> String {
        if change.isUntracked {
            let url = root.appendingPathComponent(change.path)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return "(can't read \(change.path))"
            }
            if data.prefix(8000).contains(0) { return "Binary file" }
            let text = String(decoding: data.prefix(400_000), as: UTF8.self)
            return "new file\n" + text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "+" + $0 }.joined(separator: "\n")
        }
        let base = ["diff", "--no-color", "--no-ext-diff"]
        if let text = try? await run(base + ["HEAD", "--", change.path], in: root, trim: false,
                                     extraEnvironment: literalPaths) {
            return text.isEmpty ? "No content changes (mode or metadata only)." : text
        }
        // No commits yet: compare the index with the working tree, plus what's staged.
        let staged = (try? await run(base + ["--cached", "--", change.path], in: root, trim: false,
                                     extraEnvironment: literalPaths)) ?? ""
        let unstaged = (try? await run(base + ["--", change.path], in: root, trim: false,
                                       extraEnvironment: literalPaths)) ?? ""
        return staged + unstaged
    }

    /// Commits exactly `changes` with `message`. Anything else that was already staged stays staged
    /// and is not part of the commit (`git commit --only`).
    static func commit(_ changes: [GitChange], message: String, in root: URL) async throws {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GitError.emptyMessage }
        guard !changes.isEmpty else { throw GitError.nothingSelected }

        // New files and unstaged edits/deletions must be in the index before `commit --only` sees them.
        let toAdd = changes.filter { $0.isUntracked || $0.worktree != " " }.map(\.path)
        if !toAdd.isEmpty {
            try await run(["add", "-A", "--"] + toAdd, in: root, extraEnvironment: literalPaths)
        }
        try await run(["commit", "--only", "-m", text, "--"] + changes.map(\.path),
                      in: root, extraEnvironment: literalPaths)
    }
}

/// One changed file from `git status --porcelain`.
struct GitChange: Identifiable, Hashable {
    let path: String
    /// Index (staged) status letter.
    let index: Character
    /// Working-tree status letter.
    let worktree: Character

    var id: String { path }
    var isUntracked: Bool { index == "?" }

    /// Single-letter badge: A, M, D, U (conflict) or ? (untracked).
    var badge: String {
        if isUntracked { return "?" }
        if index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") {
            return "U"
        }
        if index == "D" || worktree == "D" { return "D" }
        if index == "A" { return "A" }
        return "M"
    }

    var fileName: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}
