import AppKit
import SwiftUI

/// One log window per project; opening it again brings the existing one to the front.
enum LogWindow {
    private static var controllers: [String: NSWindowController] = [:]
    private static var observers: [String: NSObjectProtocol] = [:]

    @MainActor
    static func show(project: XcodeProject, runner: BuildRunner) {
        let key = project.id
        NSApp.activate(ignoringOtherApps: true)
        if let existing = controllers[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Logs — \(project.name)"
        window.minSize = NSSize(width: 560, height: 300)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: LogWindowView(projectID: project.id, projectName: project.name)
                .environmentObject(runner)
        )
        window.center()
        window.setFrameAutosaveName("LogWindow")

        let controller = NSWindowController(window: window)
        controllers[key] = controller
        // The session exists from now on, so Preserve Log can be turned on before the first run.
        let session = runner.session(ensuring: project)
        observers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            // Preserve Log only lasts while the window is open.
            Task { @MainActor in session.preserveLog = false }
            controllers[key] = nil
            if let token = observers.removeValue(forKey: key) {
                NotificationCenter.default.removeObserver(token)
            }
        }
        DockPresence.track(window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Line classification

enum LogLineKind {
    case error, warning, success, command, normal

    init(_ line: String) {
        if line.contains(": error:") || line.hasPrefix("error:") || line.hasPrefix("✗") || line.contains("** BUILD FAILED **")
            || line.contains("Fatal error") || line.contains(" E/") || line.hasPrefix("E/") || line.hasPrefix("e: ") {
            self = .error
        } else if line.contains(": warning:") || line.hasPrefix("warning:") || line.contains(" W/") || line.hasPrefix("W/")
                    || line.hasPrefix("w: ") {
            self = .warning
        } else if line.hasPrefix("✓") || line.contains("** BUILD SUCCEEDED **") || line.hasPrefix("BUILD SUCCESSFUL") {
            self = .success
        } else if line.hasPrefix("$ ") || line.hasPrefix("▶") || line.hasPrefix("■") || line.hasPrefix("━━") {
            self = .command
        } else {
            self = .normal
        }
    }

    var color: NSColor {
        switch self {
        case .error: return .systemRed
        case .warning: return .systemOrange
        case .success: return .systemGreen
        case .command: return .controlAccentColor
        case .normal: return .labelColor
        }
    }
}

enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case issues = "Errors & Warnings"
    case errors = "Errors"

    var id: String { rawValue }

    func allows(_ kind: LogLineKind) -> Bool {
        switch self {
        case .all: return true
        case .issues: return kind == .error || kind == .warning
        case .errors: return kind == .error
        }
    }
}

// MARK: - Filter

/// Text filter: every term must appear (`-term` excludes, "quoted phrases" stay together),
/// or one regular expression when regex mode is on.
struct LogFilter {
    let include: [String]
    let exclude: [String]
    let regex: NSRegularExpression?
    let caseSensitive: Bool
    /// The text is a regex that doesn't compile.
    let isInvalid: Bool

    init(_ text: String, useRegex: Bool, caseSensitive: Bool) {
        self.caseSensitive = caseSensitive
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if useRegex, !trimmed.isEmpty {
            let compiled = try? NSRegularExpression(pattern: trimmed, options: caseSensitive ? [] : [.caseInsensitive])
            regex = compiled
            isInvalid = compiled == nil
            include = []
            exclude = []
            return
        }
        regex = nil
        isInvalid = false
        var include: [String] = [], exclude: [String] = []
        for term in Self.tokens(trimmed) {
            if term.count > 1, term.hasPrefix("-") {
                exclude.append(String(term.dropFirst()))
            } else {
                include.append(term)
            }
        }
        self.include = include
        self.exclude = exclude
    }

    var isEmpty: Bool { include.isEmpty && exclude.isEmpty && regex == nil }

    private static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character == " " && !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private func contains(_ line: String, _ term: String) -> Bool {
        caseSensitive ? line.contains(term) : line.range(of: term, options: .caseInsensitive) != nil
    }

    func matches(_ line: String) -> Bool {
        if let regex {
            return regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
        if isInvalid { return true }
        return include.allSatisfy { contains(line, $0) } && !exclude.contains { contains(line, $0) }
    }

    /// Ranges to highlight in a matching line.
    func highlights(in line: String) -> [NSRange] {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let regex {
            return regex.matches(in: line, range: all).map(\.range).filter { $0.length > 0 }
        }
        var ranges: [NSRange] = []
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        for term in include where !term.isEmpty {
            var search = all
            while search.length > 0 {
                let found = ns.range(of: term, options: options, range: search)
                if found.location == NSNotFound { break }
                ranges.append(found)
                let next = NSMaxRange(found)
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        return ranges
    }
}

// MARK: - Window content

private struct LogWindowView: View {
    let projectID: String
    let projectName: String

    @EnvironmentObject private var runner: BuildRunner
    @State private var filterText = ""
    @AppStorage("logFilterRegex") private var useRegex = false
    @AppStorage("logFilterCaseSensitive") private var caseSensitive = false
    @AppStorage("logLevelFilter") private var level: LogLevelFilter = .all
    @AppStorage("logFollow") private var follow = true

    private var session: RunSession? { runner.session(for: projectID) }
    private var filter: LogFilter { LogFilter(filterText, useRegex: useRegex, caseSensitive: caseSensitive) }

    var body: some View {
        let allLines = session?.logLines ?? []
        let filter = filter
        let shown = (filter.isEmpty && level == .all)
            ? allLines
            : allLines.filter { level.allows(LogLineKind($0)) && filter.matches($0) }

        VStack(spacing: 0) {
            toolbar(filter: filter, shown: shown)
            Divider()
            if session == nil || (allLines.isEmpty && session?.phase == .idle) {
                placeholder
            } else {
                LogTextView(
                    lines: shown,
                    filterKey: "\(filterText)|\(useRegex)|\(caseSensitive)|\(level.rawValue)",
                    filter: filter,
                    follow: follow
                )
            }
            Divider()
            statusBar(shown: shown.count, total: allLines.count)
        }
    }

    private func toolbar(filter: LogFilter, shown: [String]) -> some View {
        HStack(spacing: 8) {
            SearchField(text: $filterText, prompt: useRegex ? "Regular expression" : "Filter: text or tag, \"a phrase\", -exclude")
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.red.opacity(filter.isInvalid ? 0.8 : 0))
                )
                .help("Every word must appear in the line. Prefix a word with - to hide lines containing it. Use quotes for phrases.")

            Toggle(isOn: $caseSensitive) { Text("Aa") }
                .toggleStyle(.button)
                .help("Match case")
            Toggle(isOn: $useRegex) { Text(".*").font(.body.monospaced()) }
                .toggleStyle(.button)
                .help("Use a regular expression")

            Picker("Level", selection: $level) {
                ForEach(LogLevelFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Show all lines, or only errors and warnings")

            Divider().frame(height: 18)

            Toggle(isOn: $follow) { Image(systemName: "arrow.down.to.line") }
                .toggleStyle(.button)
                .help("Follow: keep scrolling to the newest line")
            Toggle(isOn: Binding(
                get: { session?.preserveLog ?? false },
                set: { session?.preserveLog = $0 }
            )) {
                Image(systemName: session?.preserveLog == true ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .disabled(session == nil)
            .help("Preserve Log: keep this output when you stop and run again (new runs are added below a divider). Turns off when this window closes.")
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(shown.joined(separator: "\n"), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy the lines shown")
            Button {
                session?.clearLog()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(session == nil)
            .help("Clear the window (the log file is kept)")
            Button {
                NSWorkspace.shared.open(session?.logURL ?? runner.logsDirectory)
            } label: {
                Image(systemName: "doc.text")
            }
            .help("Open the full log file")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func statusBar(shown: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            if let session {
                Text(session.phase.title)
                    .foregroundStyle(session.phase == .streaming ? Color.green : Color.secondary)
                if session.errorCount > 0 {
                    Text("\(session.errorCount) error\(session.errorCount == 1 ? "" : "s")").foregroundStyle(.red)
                }
                if session.warningCount > 0 {
                    Text("\(session.warningCount) warning\(session.warningCount == 1 ? "" : "s")").foregroundStyle(.orange)
                }
            }
            Spacer()
            if session?.preserveLog == true {
                Label("Preserving log across runs", systemImage: "pin.fill")
                    .foregroundStyle(.secondary)
            }
            Text(shown == total ? "\(total) lines" : "Showing \(shown) of \(total) lines")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No logs yet for \(projectName).")
                .foregroundStyle(.secondary)
            Text("Run the project and its build and app output appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Text view

/// Read-only NSTextView: fast for thousands of lines, with multi-line selection.
/// New lines are appended when possible instead of rebuilding the whole text.
private struct LogTextView: NSViewRepresentable {
    let lines: [String]
    /// Changes whenever the filter or level changes (forces a rebuild).
    let filterKey: String
    let filter: LogFilter
    let follow: Bool

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    final class Coordinator {
        var key = ""
        var count = 0
        var first: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.layoutManager?.allowsNonContiguousLayout = true
        // Long lines scroll sideways rather than wrapping.
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        let state = context.coordinator

        let canAppend = state.key == filterKey && state.count > 0 && lines.count >= state.count
            && lines.first == state.first
        if canAppend && lines.count == state.count { return }

        storage.beginEditing()
        if canAppend {
            storage.append(render(lines[state.count...], leadingNewline: true))
        } else {
            storage.setAttributedString(render(lines[...], leadingNewline: false))
        }
        storage.endEditing()

        state.key = filterKey
        state.count = lines.count
        state.first = lines.first

        if follow {
            Self.scrollToBottom(scrollView, textView: textView)
        }
    }

    /// Follow scrolls down only: the horizontal position stays where the user left it,
    /// even when the newest line is long.
    private static func scrollToBottom(_ scrollView: NSScrollView, textView: NSTextView) {
        let clip = scrollView.contentView
        let x = clip.bounds.origin.x
        // Lay out the end of the text so the document height includes the newest lines.
        let length = textView.string.utf16.count
        if length > 0 {
            textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: length - 1, length: 1))
        }
        let documentHeight = textView.frame.height
        let y = max(0, documentHeight - clip.bounds.height)
        clip.scroll(to: NSPoint(x: x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func render(_ slice: ArraySlice<String>, leadingNewline: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let highlight = NSColor.systemYellow.withAlphaComponent(0.35)
        for (offset, line) in slice.enumerated() {
            if offset > 0 || leadingNewline {
                result.append(NSAttributedString(string: "\n", attributes: [.font: Self.font]))
            }
            let piece = NSMutableAttributedString(string: line, attributes: [
                .font: Self.font,
                .foregroundColor: LogLineKind(line).color,
            ])
            if !filter.isEmpty {
                for range in filter.highlights(in: line) {
                    piece.addAttribute(.backgroundColor, value: highlight, range: range)
                }
            }
            result.append(piece)
        }
        return result
    }
}
