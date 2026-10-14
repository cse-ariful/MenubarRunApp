import AppKit

/// Xcode-like syntax colouring for the file browser. Colours are dynamic system colours,
/// so they follow light and dark mode.
enum SyntaxHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

    enum Token {
        case keyword, string, comment, number, type, function, attribute, directive, heading, link
    }

    static func color(_ token: Token) -> NSColor {
        switch token {
        case .keyword: return .systemPink
        case .string: return .systemRed
        case .comment: return .systemGray
        case .number: return .systemBlue
        case .type: return .systemPurple
        case .function: return .systemTeal
        case .attribute: return .systemOrange
        case .directive: return .systemBrown
        case .heading: return .systemPink
        case .link: return .systemBlue
        }
    }

    /// Longer texts are shown without colours to keep the window responsive.
    static let maxHighlightLength = 600_000

    /// Display name of the language detected for `url` ("Plain Text" when unknown).
    static func languageName(for url: URL) -> String {
        switch Grammar.detect(url) {
        case let .code(language): return language.name
        case .markup: return url.pathExtension.lowercased() == "plist" ? "Property List" : "XML"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .markdown: return "Markdown"
        case .plain: return "Plain Text"
        }
    }

    static func highlight(_ text: String, for url: URL) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        guard (text as NSString).length <= maxHighlightLength else { return result }

        switch Grammar.detect(url) {
        case let .code(language): CodeScanner(language: language, text: text).apply(to: result)
        case .markup: applyRules(markupRules, to: result)
        case .json: applyRules(jsonRules, to: result)
        case .yaml: applyRules(yamlRules, to: result)
        case .markdown: applyRules(markdownRules, to: result)
        case .plain: break
        }
        return result
    }

    static func style(_ string: NSMutableAttributedString, _ range: NSRange, _ token: Token) {
        guard range.length > 0 else { return }
        string.addAttribute(.foregroundColor, value: color(token), range: range)
        if token == .keyword || token == .heading {
            string.addAttribute(.font, value: boldFont, range: range)
        }
    }

    // MARK: - Regex grammars (markup, JSON, YAML, Markdown)

    struct Rule {
        let regex: NSRegularExpression
        let token: Token
        /// Capture group to colour (0 = whole match).
        let group: Int

        init(_ pattern: String, _ token: Token, group: Int = 0, options: NSRegularExpression.Options = []) {
            // Patterns are constants; a bad one is a programming error.
            regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.token = token
            self.group = group
        }
    }

    /// Later rules win, so comments come last.
    static func applyRules(_ rules: [Rule], to string: NSMutableAttributedString) {
        let text = string.string
        let all = NSRange(location: 0, length: (text as NSString).length)
        for rule in rules {
            rule.regex.enumerateMatches(in: text, range: all) { match, _, _ in
                guard let match, rule.group < match.numberOfRanges else { return }
                let range = match.range(at: rule.group)
                if range.location != NSNotFound { style(string, range, rule.token) }
            }
        }
    }

    static let markupRules: [Rule] = [
        Rule(#"</?([A-Za-z_][\w:.\-]*)"#, .keyword, group: 1),
        Rule(#"\s([A-Za-z_:][\w:.\-]*)\s*="#, .attribute, group: 1),
        Rule(#"=\s*("[^"]*"|'[^']*')"#, .string, group: 1),
        Rule(#"&#?\w+;"#, .number),
        Rule(#"<!\[CDATA\[[\s\S]*?\]\]>"#, .string),
        Rule(#"<[?!][\s\S]*?>"#, .directive),
        Rule(#"<!--[\s\S]*?-->"#, .comment),
    ]

    static let jsonRules: [Rule] = [
        Rule(#"-?\b\d+(\.\d+)?([eE][+\-]?\d+)?\b"#, .number),
        Rule(#"\b(true|false|null)\b"#, .keyword),
        Rule(#""(?:[^"\\\n]|\\.)*""#, .string),
        Rule(#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#, .attribute),
    ]

    static let yamlRules: [Rule] = [
        Rule(#"\b-?\d+(\.\d+)?\b"#, .number),
        Rule(#"\b(true|false|yes|no|null|on|off)\b"#, .keyword, options: [.caseInsensitive]),
        Rule(#"^(\s*-?\s*)([^\s#:][^:#\n]*?)(?=:(\s|$))"#, .attribute, group: 2, options: [.anchorsMatchLines]),
        Rule(#"[&*][\w\-]+"#, .directive),
        Rule(#""(?:[^"\\\n]|\\.)*"|'[^'\n]*'"#, .string),
        Rule(#"(^|\s)#.*$"#, .comment, options: [.anchorsMatchLines]),
    ]

    static let markdownRules: [Rule] = [
        Rule(#"^\s*([-*+]|\d+\.)\s"#, .keyword, group: 1, options: [.anchorsMatchLines]),
        Rule(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .type),
        Rule(#"\[[^\]\n]+\]\([^)\n]+\)"#, .link),
        Rule(#"`[^`\n]+`"#, .string),
        Rule(#"^>.*$"#, .comment, options: [.anchorsMatchLines]),
        Rule(#"^#{1,6}\s.*$"#, .heading, options: [.anchorsMatchLines]),
        Rule(#"^```[\s\S]*?^```"#, .string, options: [.anchorsMatchLines]),
    ]
}

// MARK: - Language detection

enum Grammar {
    case code(CodeLanguage)
    case markup, json, yaml, markdown, plain

    static func detect(_ url: URL) -> Grammar {
        let name = url.lastPathComponent
        switch name {
        case "Podfile", "Gemfile", "Fastfile", "Appfile", "Matchfile", "Brewfile", "Dangerfile", "Rakefile":
            return .code(.ruby)
        case "Makefile", "Dockerfile", ".gitignore", ".gitattributes", ".env", "CODEOWNERS":
            return .code(.hashComments)
        case "Package.resolved":
            return .json
        case "Podfile.lock", "pubspec.lock":
            return .yaml
        default:
            break
        }
        switch url.pathExtension.lowercased() {
        case "swift", "swiftinterface": return .code(.swift)
        case "m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp", "hh", "metal", "modulemap": return .code(.cFamily)
        case "kt", "kts": return .code(.kotlin)
        case "java": return .code(.java)
        case "gradle", "groovy": return .code(.groovy)
        case "dart": return .code(.dart)
        case "js", "mjs", "cjs", "jsx", "ts", "tsx": return .code(.javaScript)
        case "py": return .code(.python)
        case "rb", "podspec": return .code(.ruby)
        case "sh", "bash", "zsh", "command": return .code(.shell)
        case "pbxproj", "xcconfig", "strings", "stringsdict": return .code(.plistText)
        case "properties", "toml", "ini", "cfg", "conf": return .code(.hashComments)
        case "json", "jsonc", "arb", "geojson": return .json
        case "yml", "yaml": return .yaml
        case "md", "markdown": return .markdown
        case "xml", "plist", "storyboard", "xib", "html", "htm", "xcscheme", "entitlements", "svg",
             "xcworkspacedata", "xcsettings":
            return .markup
        default:
            return .plain
        }
    }
}

struct CodeLanguage {
    let name: String
    var lineComments: [String] = ["//"]
    var blockComment: (open: String, close: String)? = ("/*", "*/")
    var quotes: Set<Character> = ["\""]
    /// Quote characters whose strings may span lines (e.g. JavaScript template literals).
    var multilineQuotes: Set<Character> = []
    /// """ / ''' strings.
    var tripleQuotes = false
    var keywords: Set<String> = []
    var literals: Set<String> = ["true", "false"]
    /// `#if`, `#include`, `#selector`…
    var hashDirectives = false
    /// `@MainActor`, `@Override`…
    var atAttributes = false
    /// Capitalized identifiers are coloured as types.
    var capitalizedTypes = true

    static let swift = CodeLanguage(
        name: "Swift", tripleQuotes: true,
        keywords: ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
                   "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public",
                   "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue",
                   "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
                   "throw", "switch", "where", "while", "as", "is", "super", "self", "Self", "throws", "try", "async",
                   "await", "some", "any", "lazy", "weak", "unowned", "mutating", "nonmutating", "override", "final",
                   "required", "convenience", "dynamic", "optional", "indirect", "nonisolated", "isolated", "actor",
                   "macro", "consuming", "borrowing", "get", "set", "willSet", "didSet", "Type", "Protocol"],
        literals: ["true", "false", "nil"],
        hashDirectives: true, atAttributes: true)

    static let cFamily = CodeLanguage(
        name: "C / Objective-C", quotes: ["\"", "'"],
        keywords: ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
                   "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short",
                   "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
                   "while", "class", "namespace", "template", "typename", "public", "private", "protected", "virtual",
                   "override", "new", "delete", "this", "using", "try", "catch", "throw", "constexpr", "nullptr",
                   "bool", "self", "super", "id", "instancetype", "nonatomic", "atomic", "strong", "weak", "assign",
                   "copy", "readonly", "readwrite", "nullable", "nonnull", "__block", "__weak", "IBOutlet",
                   "IBAction", "BOOL", "YES", "NO", "SEL", "Class"],
        literals: ["true", "false", "nil", "NULL", "Nil", "YES", "NO"],
        hashDirectives: true, atAttributes: true)

    static let kotlin = CodeLanguage(
        name: "Kotlin", tripleQuotes: true,
        keywords: ["as", "break", "class", "continue", "do", "else", "for", "fun", "if", "in", "interface", "is",
                   "object", "package", "return", "super", "this", "throw", "try", "typealias", "typeof", "val",
                   "var", "when", "while", "by", "catch", "constructor", "delegate", "dynamic", "field", "file",
                   "finally", "get", "import", "init", "param", "property", "receiver", "set", "setparam", "where",
                   "actual", "abstract", "annotation", "companion", "const", "crossinline", "data", "enum", "expect",
                   "external", "final", "infix", "inline", "inner", "internal", "lateinit", "noinline", "open",
                   "operator", "out", "override", "private", "protected", "public", "reified", "sealed", "suspend",
                   "tailrec", "vararg", "value"],
        literals: ["true", "false", "null"], atAttributes: true)

    static let java = CodeLanguage(
        name: "Java", quotes: ["\"", "'"], tripleQuotes: true,
        keywords: ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
                   "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
                   "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native",
                   "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp",
                   "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void",
                   "volatile", "while", "var", "record", "sealed", "permits", "yield"],
        literals: ["true", "false", "null"], atAttributes: true)

    static let groovy = CodeLanguage(
        name: "Gradle", quotes: ["\"", "'"], tripleQuotes: true,
        keywords: ["def", "class", "interface", "if", "else", "for", "while", "return", "new", "import", "in", "as",
                   "apply", "plugin", "plugins", "android", "dependencies", "repositories", "buildscript",
                   "allprojects", "subprojects", "implementation", "api", "compileOnly", "runtimeOnly",
                   "testImplementation", "androidTestImplementation", "kapt", "ksp", "classpath", "id", "version",
                   "task", "ext", "include", "rootProject", "project"],
        literals: ["true", "false", "null"], atAttributes: true)

    static let dart = CodeLanguage(
        name: "Dart", quotes: ["\"", "'"], tripleQuotes: true,
        keywords: ["abstract", "as", "assert", "async", "await", "base", "break", "case", "catch", "class", "const",
                   "continue", "covariant", "default", "deferred", "do", "dynamic", "else", "enum", "export",
                   "extends", "extension", "external", "factory", "final", "finally", "for", "Function", "get",
                   "hide", "if", "implements", "import", "in", "interface", "is", "late", "library", "mixin", "new",
                   "on", "operator", "part", "required", "rethrow", "return", "sealed", "set", "show", "static",
                   "super", "switch", "sync", "this", "throw", "try", "typedef", "var", "void", "when", "while",
                   "with", "yield"],
        literals: ["true", "false", "null"], atAttributes: true)

    static let javaScript = CodeLanguage(
        name: "JavaScript / TypeScript", quotes: ["\"", "'", "`"], multilineQuotes: ["`"],
        keywords: ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
                   "else", "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof",
                   "let", "new", "return", "super", "switch", "this", "throw", "try", "typeof", "var", "void",
                   "while", "with", "yield", "async", "await", "of", "from", "as", "interface", "type", "enum",
                   "implements", "private", "public", "protected", "readonly", "static", "declare", "namespace",
                   "abstract", "keyof"],
        literals: ["true", "false", "null", "undefined"], atAttributes: true)

    static let python = CodeLanguage(
        name: "Python", lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"], tripleQuotes: true,
        keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
                   "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
                   "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "self"],
        literals: ["True", "False", "None"], atAttributes: true)

    static let ruby = CodeLanguage(
        name: "Ruby", lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"],
        keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif",
                   "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry",
                   "return", "self", "super", "then", "undef", "unless", "until", "when", "while", "yield",
                   "require", "platform", "target", "pod", "use_frameworks!", "lane", "desc", "source", "gem"],
        literals: ["true", "false", "nil"])

    static let shell = CodeLanguage(
        name: "Shell", lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"],
        keywords: ["if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in",
                   "function", "return", "exit", "local", "export", "readonly", "set", "unset", "shift", "source",
                   "echo", "printf", "cd", "test"],
        literals: ["true", "false"], capitalizedTypes: false)

    /// .pbxproj, .xcconfig, .strings
    static let plistText = CodeLanguage(name: "Xcode Text", capitalizedTypes: false)

    static let hashComments = CodeLanguage(
        name: "Plain Text", lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"], literals: [],
        capitalizedTypes: false)
}

// MARK: - Scanner for code languages

/// Single pass over UTF-16 code units: comments, strings, numbers, keywords, types, calls, @attributes, #directives.
private struct CodeScanner {
    let language: CodeLanguage
    let chars: [unichar]

    private let lineComments: [[unichar]]
    private let blockOpen: [unichar]?
    private let blockClose: [unichar]?
    private let quotes: Set<unichar>
    private let multiline: Set<unichar>

    init(language: CodeLanguage, text: String) {
        self.language = language
        chars = Array(text.utf16)
        lineComments = language.lineComments.map { Array($0.utf16) }
        blockOpen = language.blockComment.map { Array($0.open.utf16) }
        blockClose = language.blockComment.map { Array($0.close.utf16) }
        quotes = Set(language.quotes.compactMap { $0.utf16.first })
        multiline = Set(language.multilineQuotes.compactMap { $0.utf16.first })
    }

    private static let newline: unichar = 10
    private static let backslash: unichar = 92
    private static let at: unichar = 64
    private static let hash: unichar = 35
    private static let openParen: unichar = 40

    private func starts(_ pattern: [unichar], at index: Int) -> Bool {
        guard index + pattern.count <= chars.count else { return false }
        for k in 0..<pattern.count where chars[index + k] != pattern[k] { return false }
        return true
    }

    private func find(_ pattern: [unichar], from index: Int) -> Int? {
        var i = index
        while i + pattern.count <= chars.count {
            if starts(pattern, at: i) { return i }
            i += 1
        }
        return nil
    }

    private static func isIdentStart(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127
    }

    private static func isIdent(_ c: unichar) -> Bool {
        isIdentStart(c) || (c >= 48 && c <= 57)
    }

    private static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

    private func lineEnd(from index: Int) -> Int {
        var i = index
        while i < chars.count && chars[i] != Self.newline { i += 1 }
        return i
    }

    private func identifierEnd(from index: Int) -> Int {
        var j = index
        while j < chars.count && Self.isIdent(chars[j]) { j += 1 }
        // Ruby's `use_frameworks!` / `defined?`
        if j < chars.count, language.name == "Ruby", chars[j] == 33 || chars[j] == 63 { j += 1 }
        return j
    }

    func apply(to string: NSMutableAttributedString) {
        let count = chars.count
        var i = 0
        func mark(_ start: Int, _ end: Int, _ token: SyntaxHighlighter.Token) {
            SyntaxHighlighter.style(string, NSRange(location: start, length: max(0, min(end, count) - start)), token)
        }

        while i < count {
            let c = chars[i]

            if let open = blockOpen, let close = blockClose, starts(open, at: i) {
                let end = find(close, from: i + open.count).map { $0 + close.count } ?? count
                mark(i, end, .comment)
                i = end
                continue
            }
            if lineComments.contains(where: { starts($0, at: i) }) {
                let end = lineEnd(from: i)
                mark(i, end, .comment)
                i = end
                continue
            }
            if quotes.contains(c) {
                // """ / ''' strings
                if language.tripleQuotes, i + 2 < count, chars[i + 1] == c, chars[i + 2] == c {
                    let delimiter = [c, c, c]
                    let end = find(delimiter, from: i + 3).map { $0 + 3 } ?? count
                    mark(i, end, .string)
                    i = end
                    continue
                }
                var j = i + 1
                while j < count {
                    let d = chars[j]
                    if d == Self.backslash { j += 2; continue }
                    if d == c { j += 1; break }
                    if d == Self.newline && !multiline.contains(c) { break }
                    j += 1
                }
                mark(i, j, .string)
                i = min(j, count)
                continue
            }
            if Self.isDigit(c), i == 0 || !Self.isIdent(chars[i - 1]) {
                var j = i + 1
                while j < count, Self.isIdent(chars[j]) || (chars[j] == 46 && j + 1 < count && Self.isDigit(chars[j + 1])) {
                    j += 1
                }
                mark(i, j, .number)
                i = j
                continue
            }
            if c == Self.at, language.atAttributes, i + 1 < count, Self.isIdentStart(chars[i + 1]) {
                let end = identifierEnd(from: i + 1)
                mark(i, end, .attribute)
                i = end
                continue
            }
            if c == Self.hash, language.hashDirectives, i + 1 < count, Self.isIdentStart(chars[i + 1]) {
                let end = identifierEnd(from: i + 1)
                mark(i, end, .directive)
                i = end
                continue
            }
            if Self.isIdentStart(c) {
                let end = identifierEnd(from: i)
                let word = String(utf16CodeUnits: Array(chars[i..<end]), count: end - i)
                if language.keywords.contains(word) || language.literals.contains(word) {
                    mark(i, end, .keyword)
                } else if language.capitalizedTypes, let first = word.unicodeScalars.first,
                          CharacterSet.uppercaseLetters.contains(first) {
                    mark(i, end, .type)
                } else {
                    var k = end
                    while k < count, chars[k] == 32 { k += 1 }
                    if k < count, chars[k] == Self.openParen, language.capitalizedTypes {
                        mark(i, end, .function)
                    }
                }
                i = end
                continue
            }
            i += 1
        }
    }
}
