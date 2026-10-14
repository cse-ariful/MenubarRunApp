import AppKit
import SwiftUI

/// Rendered Markdown: headings, paragraphs, lists (incl. task lists), quotes, code blocks, tables,
/// rules and local images. Inline styling (bold, italic, `code`, links) uses Foundation's Markdown parser.
struct MarkdownPreview: View {
    let blocks: [MarkdownBlock]
    /// Folder of the Markdown file, for relative image paths.
    let baseURL: URL

    init(text: String, baseURL: URL) {
        blocks = MarkdownBlock.parse(text)
        self.baseURL = baseURL
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.inline(text))
                    .font(.system(size: Self.headingSize(level), weight: level <= 2 ? .bold : .semibold))
                    .padding(.top, level <= 2 ? 8 : 4)
                if level <= 2 { Divider() }
            }
        case let .paragraph(text):
            Text(Self.inline(text))
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case let .list(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(for: item)
                        Text(Self.inline(item.text))
                            .font(.system(size: 13.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(Self.inline(text))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .code(language, code):
            VStack(alignment: .leading, spacing: 4) {
                if !language.isEmpty {
                    Text(language)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .fixedSize()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        case let .table(header, rows):
            table(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        case let .image(alt, path):
            image(alt: alt, path: path)
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownBlock.ListItem) -> some View {
        switch item.kind {
        case let .ordered(number):
            Text("\(number).")
                .font(.system(size: 13.5).monospacedDigit())
                .foregroundStyle(.secondary)
        case let .task(done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .foregroundStyle(done ? Color.accentColor : Color.secondary)
        case .bullet:
            Text(item.level == 0 ? "•" : "◦")
                .foregroundStyle(.secondary)
        }
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(column < header.count ? header[column] : "", bold: true, shade: 0.06)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            cell(column < row.count ? row[column] : "", bold: false,
                                 shade: index.isMultiple(of: 2) ? 0 : 0.03)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
        }
    }

    private func cell(_ text: String, bold: Bool, shade: Double) -> some View {
        Text(Self.inline(text))
            .font(.system(size: 13, weight: bold ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.primary.opacity(shade))
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1)
            }
    }

    @ViewBuilder
    private func image(alt: String, path: String) -> some View {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseURL.appendingPathComponent(path)
        if !path.contains("://"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: min(image.size.width, 760), alignment: .leading)
                .help(alt)
        } else {
            Label(alt.isEmpty ? path : alt, systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(path)
        }
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 26
        case 2: return 21
        case 3: return 17
        case 4: return 15
        default: return 13.5
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Block parser

enum MarkdownBlock {
    struct ListItem {
        enum Kind {
            case bullet
            case ordered(Int)
            case task(done: Bool)
        }
        let level: Int
        let kind: Kind
        var text: String
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ListItem])
    case quote(String)
    case code(language: String, text: String)
    case table(header: [String], rows: [[String]])
    case rule
    case image(alt: String, path: String)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)  // constant patterns
    }

    private static let headingRegex = regex(#"^(#{1,6})\s+(.*?)\s*#*\s*$"#)
    private static let bulletRegex = regex(#"^(\s*)[-*+]\s+(.*)$"#)
    private static let orderedRegex = regex(#"^(\s*)(\d+)[.)]\s+(.*)$"#)
    private static let ruleRegex = regex(#"^\s*([-*_])(\s*\1){2,}\s*$"#)
    private static let separatorRegex = regex(#"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#)
    private static let imageRegex = regex(#"^\s*!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)\s*$"#)

    private static func groups(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [ListItem] = []
        var quote: [String] = []
        var i = 0

        func flush() {
            if !paragraph.isEmpty {
                // Soft-wrapped lines join with a space; a line ending in two spaces keeps its break.
                let joined = paragraph.reduce("") { text, line in
                    text.isEmpty ? line : (text.hasSuffix("\n") ? text + line : text + " " + line)
                }
                blocks.append(.paragraph(joined))
                paragraph = []
            }
            if !listItems.isEmpty {
                blocks.append(.list(listItems))
                listItems = []
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }

            // HTML comments are hidden, like on GitHub.
            if trimmed.hasPrefix("<!--") {
                flush()
                while i < lines.count, !lines[i].contains("-->") { i += 1 }
                i += 1
                continue
            }

            if let match = groups(headingRegex, line) {
                flush()
                blocks.append(.heading(level: match[1].count, text: match[2]))
                i += 1
                continue
            }

            if groups(ruleRegex, line) != nil {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }

            if let match = groups(imageRegex, line) {
                flush()
                blocks.append(.image(alt: match[1], path: match[2]))
                i += 1
                continue
            }

            // Table: a row with pipes followed by a --- separator row.
            if trimmed.contains("|"), i + 1 < lines.count, groups(separatorRegex, lines[i + 1]) != nil {
                flush()
                let header = tableCells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[i]))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !listItems.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }

            if let match = groups(bulletRegex, line) {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                let level = match[1].count / 2
                var body = match[2]
                var kind = ListItem.Kind.bullet
                if body.hasPrefix("[ ] ") || body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                    kind = .task(done: !body.hasPrefix("[ ]"))
                    body = String(body.dropFirst(4))
                }
                listItems.append(ListItem(level: level, kind: kind, text: body))
                i += 1
                continue
            }

            if let match = groups(orderedRegex, line) {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                listItems.append(ListItem(level: match[1].count / 2, kind: .ordered(Int(match[2]) ?? 1), text: match[3]))
                i += 1
                continue
            }

            // Continuation lines
            if !listItems.isEmpty, line.hasPrefix(" ") {
                listItems[listItems.count - 1].text += " " + trimmed
            } else if !quote.isEmpty {
                quote.append(trimmed)
            } else {
                if !listItems.isEmpty { flush() }
                // Two trailing spaces mean a line break; otherwise lines join like in Markdown.
                paragraph.append(line.hasSuffix("  ") ? trimmed + "\n" : trimmed)
            }
            i += 1
        }
        flush()
        return blocks
    }
}
