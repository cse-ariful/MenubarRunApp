import AppKit
import SwiftUI

/// One file browser window per project folder; opening it again brings the existing one to the front.
enum FileBrowserWindow {
    private static var controllers: [URL: NSWindowController] = [:]
    private static var observers: [URL: NSObjectProtocol] = [:]

    @MainActor
    static func show(project: XcodeProject) {
        let root = project.directory
        NSApp.activate(ignoringOtherApps: true)
        if let existing = controllers[root] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(project.name) — Files"
        window.minSize = NSSize(width: 700, height: 420)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FileBrowserView(root: root))
        window.center()
        window.setFrameAutosaveName("FileBrowserWindow")

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

// MARK: - File tree

enum FileTree {
    /// Build output, dependency caches and VCS folders aren't worth browsing.
    static let skipped: Set<String> = [".git", "build", "DerivedData", ".build", "node_modules", ".dart_tool",
                                       ".gradle", ".idea", ".swiftpm", "xcuserdata", ".symlinks"]

    static func children(of url: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { !skipped.contains($0.lastPathComponent) }
            .map { FileNode(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Files whose name contains `query`, at most `limit` of them.
    static func find(_ query: String, in root: URL, limit: Int = 300) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDirectory, url.lastPathComponent.localizedCaseInsensitiveContains(query) {
                found.append(url)
                if found.count >= limit { break }
            }
        }
        return found.sorted { $0.lastPathComponent.count < $1.lastPathComponent.count }
    }

    static func symbol(for url: URL, isDirectory: Bool) -> String {
        let ext = url.pathExtension.lowercased()
        if isDirectory {
            switch ext {
            case "xcodeproj", "xcworkspace": return "hammer"
            case "xcassets", "imageset", "appiconset": return "photo.on.rectangle"
            case "lproj": return "globe"
            default: return "folder"
            }
        }
        switch ext {
        case "swift": return "swift"
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp", "icns", "pdf": return "photo"
        case "json", "arb": return "curlybraces"
        case "md", "markdown": return "doc.richtext"
        case "plist", "xml", "storyboard", "xib", "xcscheme", "entitlements", "html", "svg":
            return "chevron.left.forwardslash.chevron.right"
        case "sh", "zsh", "bash": return "terminal"
        case "yml", "yaml", "toml", "properties", "xcconfig", "gradle", "kts": return "gearshape"
        default: return "doc.text"
        }
    }
}

final class FileNode: Identifiable, ObservableObject {
    let url: URL
    let isDirectory: Bool
    @Published private(set) var children: [FileNode]? = nil

    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    func loadChildren() {
        guard isDirectory, children == nil else { return }
        children = FileTree.children(of: url)
    }
}

@MainActor
final class FileTreeModel: ObservableObject {
    let root: URL
    let rootNode: FileNode
    @Published private(set) var results: [URL] = []
    @Published private(set) var searching = false
    private var searchTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root
        rootNode = FileNode(url: root, isDirectory: true)
        rootNode.loadChildren()
    }

    func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            searching = false
            return
        }
        searching = true
        let root = root
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)  // debounce typing
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { FileTree.find(trimmed, in: root) }.value
            guard !Task.isCancelled else { return }
            results = found
            searching = false
        }
    }

    func relativePath(_ url: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }
}

private struct FileTreeNodeView: View {
    @ObservedObject var node: FileNode
    @State private var expanded = false

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children ?? []) { child in
                    FileTreeNodeView(node: child)
                }
            } label: {
                Label(node.name, systemImage: FileTree.symbol(for: node.url, isDirectory: true))
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { expanded.toggle() }
            }
            .onChange(of: expanded) { open in
                if open { node.loadChildren() }
            }
        } else {
            Label(node.name, systemImage: FileTree.symbol(for: node.url, isDirectory: false))
                .lineLimit(1)
                .tag(node.url)
        }
    }
}

// MARK: - Document

@MainActor
final class CodeDocumentModel: ObservableObject {
    enum Content {
        case empty
        case loading
        case text(NSAttributedString, lines: Int, language: String)
        case image(NSImage)
        case message(String)
    }

    @Published private(set) var content: Content = .empty
    @Published private(set) var url: URL?
    @Published private(set) var revision = 0
    private var task: Task<Void, Never>?

    func open(_ url: URL?) {
        task?.cancel()
        self.url = url
        guard let url else {
            content = .empty
            return
        }
        content = .loading
        task = Task {
            let loaded = await Task.detached(priority: .userInitiated) { Self.load(url) }.value
            guard !Task.isCancelled, self.url == url else { return }
            content = loaded
            revision += 1
        }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp",
                                                       "bmp", "icns", "pdf"]
    private static let maxSize = 5_000_000

    nonisolated static func load(_ url: URL) -> Content {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            if let image = NSImage(contentsOf: url) { return .image(image) }
            return .message("Can't open this image.")
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .message("Can't read this file.")
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        if data.count > maxSize {
            return .message("This file is too large to preview (\(size)).")
        }

        var text: String
        if data.prefix(8000).contains(0) {
            // Binary property lists are shown as XML.
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                  let converted = String(data: xml, encoding: .utf8) else {
                return .message("Binary file · \(size)")
            }
            text = converted
        } else {
            text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        let lines = text.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
        return .text(SyntaxHighlighter.highlight(text, for: url), lines: lines,
                     language: SyntaxHighlighter.languageName(for: url))
    }
}

// MARK: - Window content

private struct FileBrowserView: View {
    let root: URL
    @StateObject private var tree: FileTreeModel
    @StateObject private var document = CodeDocumentModel()
    @State private var selection: URL?
    @State private var filter = ""
    @State private var codeView = CodeViewController()
    /// Markdown files open rendered; the toggle in the header switches to the source.
    @AppStorage("markdownPreview") private var markdownPreview = true

    private var isMarkdown: Bool {
        if case let .text(_, _, language) = document.content { return language == "Markdown" }
        return false
    }

    private var showsCode: Bool {
        if case .text = document.content { return !(isMarkdown && markdownPreview) }
        return false
    }

    @MainActor
    init(root: URL) {
        self.root = root
        _tree = StateObject(wrappedValue: FileTreeModel(root: root))
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 480)
            viewer
                .frame(minWidth: 420)
        }
        .onChange(of: selection) { url in document.open(url) }
        .onChange(of: filter) { query in tree.search(query) }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            SearchField(text: $filter, prompt: "Filter files by name")
                .padding(8)
            Divider()
            if filter.trimmingCharacters(in: .whitespaces).isEmpty {
                List(selection: $selection) {
                    ForEach(tree.rootNode.children ?? []) { node in
                        FileTreeNodeView(node: node)
                    }
                }
                .listStyle(.sidebar)
            } else if tree.searching && tree.results.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tree.results.isEmpty {
                Text("No files match “\(filter)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(tree.results, id: \.self, selection: $selection) { url in
                    HStack(spacing: 8) {
                        Image(systemName: FileTree.symbol(for: url, isDirectory: false))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text((tree.relativePath(url) as NSString).deletingLastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .tag(url)
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: Viewer

    private var viewer: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch document.content {
            case .empty:
                placeholder("Select a file to view it.", symbol: "doc.text.magnifyingglass")
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .text(text, _, _):
                if isMarkdown && markdownPreview, let url = document.url {
                    MarkdownPreview(text: text.string, baseURL: url.deletingLastPathComponent())
                        .id(document.revision)
                } else {
                    CodeTextView(text: text, revision: document.revision, controller: codeView)
                }
            case let .image(image):
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: min(image.size.width, 1200), maxHeight: min(image.size.height, 1200))
                        .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            case let .message(text):
                placeholder(text, symbol: "doc")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let url = document.url {
                Image(systemName: FileTree.symbol(for: url, isDirectory: false))
                    .foregroundStyle(.secondary)
                Text(tree.relativePath(url))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if case let .text(_, lines, language) = document.content {
                    Text("\(language) · \(lines) line\(lines == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isMarkdown {
                    Picker("Markdown view", selection: $markdownPreview) {
                        Label("Preview", systemImage: "eye").tag(true)
                        Label("Code", systemImage: "chevron.left.forwardslash.chevron.right").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Show the rendered Markdown or its source")
                }
                if showsCode {
                    Button {
                        codeView.showFind()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Find in file (⌘F)")
                }
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Open in the default app")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
            } else {
                Text(root.lastPathComponent)
                    .font(.callout.weight(.medium))
                Spacer()
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Code view (NSTextView with line numbers)

/// Lets SwiftUI buttons talk to the text view (e.g. open the find bar).
final class CodeViewController {
    weak var textView: NSTextView?

    func showFind() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }
}

private struct CodeTextView: NSViewRepresentable {
    let text: NSAttributedString
    let revision: Int
    let controller: CodeViewController

    final class Coordinator {
        var revision = -1
        var ruler: LineNumberRuler?
        var observer: NSObjectProtocol?

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = SyntaxHighlighter.font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.layoutManager?.allowsNonContiguousLayout = true

        // No wrapping: long lines scroll sideways, like Xcode.
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler

        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak ruler] _ in
            ruler?.needsDisplay = true
        }

        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.revision != revision,
              let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.revision = revision
        textView.textStorage?.setAttributedString(text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(.zero)
        context.coordinator.ruler?.textDidChange()
        controller.textView = textView
    }
}

/// Line numbers in the gutter, drawn for the visible lines only.
private final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// UTF-16 offset where each line starts.
    private var lineStarts: [Int] = [0]

    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    override var isFlipped: Bool { true }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func textDidChange() {
        guard let string = textView?.string as NSString? else { return }
        var starts = [0]
        let length = string.length
        var index = 0
        while index < length {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(lineRange)
            if index < length { starts.append(index) }
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        ruleThickness = CGFloat(digits) * 7 + 16
        scrollView?.tile()
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard !lineStarts.isEmpty else { return }

        // First line at or before the visible range (binary search).
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= characters.location { low = mid } else { high = mid - 1 }
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        var line = low
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters) {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineStarts[line])
            guard glyphIndex < layoutManager.numberOfGlyphs else { break }
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let top = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: top + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            line += 1
        }
    }
}
