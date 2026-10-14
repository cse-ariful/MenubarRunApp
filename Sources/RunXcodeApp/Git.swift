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

    var errorDescription: String? {
        switch self {
        case let .failed(command, output):
            return "git \(command) failed" + (output.isEmpty ? "." : ": \(output)")
        case let .invalidBranchName(name):
            return "“\(name)” isn't a valid branch name."
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
    private static func run(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await Shell.run(path, ["-C", directory.path] + arguments, environment: environment)
        guard result.succeeded else {
            let output = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("hint:") }
                .suffix(3)
                .joined(separator: " ")
            throw GitError.failed(command: arguments.first ?? "", output: output)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
