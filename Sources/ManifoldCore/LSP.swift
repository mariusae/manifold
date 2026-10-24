import Foundation

/// A language server to run for some files: as Manifold's settings have
/// it, with defaults for the usual languages. The command is a shell
/// command line, run on the host the files are on; one server runs per
/// workspace root, the nearest directory up from a file with one of the
/// language's markers (else `.git`, else the file's directory).
public struct LanguageServerConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var extensions: [String]
    public var command: String
    public var rootMarkers: [String]
    public var enabled: Bool

    public init(id: String, extensions: [String], command: String, rootMarkers: [String], enabled: Bool = true) {
        self.id = id
        self.extensions = extensions
        self.command = command
        self.rootMarkers = rootMarkers
        self.enabled = enabled
    }

    public static let defaults: [LanguageServerConfig] = [
        LanguageServerConfig(id: "swift", extensions: ["swift"], command: "sourcekit-lsp", rootMarkers: ["Package.swift", "*.xcodeproj", "*.xcworkspace"]),
        LanguageServerConfig(id: "go", extensions: ["go"], command: "gopls", rootMarkers: ["go.work", "go.mod"]),
        LanguageServerConfig(id: "rust", extensions: ["rs"], command: "rust-analyzer", rootMarkers: ["Cargo.toml"]),
        LanguageServerConfig(id: "python", extensions: ["py", "pyi"], command: "pyright-langserver --stdio", rootMarkers: ["pyproject.toml", "setup.py", "requirements.txt"]),
        LanguageServerConfig(id: "typescript", extensions: ["ts", "tsx", "js", "jsx", "mjs"], command: "typescript-language-server --stdio", rootMarkers: ["package.json", "tsconfig.json"]),
        LanguageServerConfig(id: "c", extensions: ["c", "h", "cc", "cpp", "cxx", "hh", "hpp", "hxx", "m", "mm"], command: "clangd", rootMarkers: ["compile_commands.json", "Makefile", "CMakeLists.txt"]),
        LanguageServerConfig(id: "zig", extensions: ["zig"], command: "zls", rootMarkers: ["build.zig"]),
    ]

    /// The table as a host's preferences change it (§7.2, `HostPreferences.lsp`):
    /// a language's command, and the markers that find its workspace root —
    /// the language's own setting, else "root" for every language. A marker
    /// may be a list, separated by commas.
    public static func applying(_ configs: [LanguageServerConfig], _ settings: [String: String]) -> [LanguageServerConfig] {
        configs.map { config in
            var c = config
            if let command = settings[c.id], !command.isEmpty { c.command = command }
            if let markers = settings[c.id + ".root"] ?? settings["root"], !markers.isEmpty {
                c.rootMarkers = markers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            return c
        }
    }

    /// The language a file is in, by its extension.
    public static func language(for path: String, in configs: [LanguageServerConfig]) -> LanguageServerConfig? {
        let ext = path.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return configs.first { $0.enabled && $0.extensions.contains(ext) }
    }

    /// The workspace root of `path`: the nearest directory up with one of
    /// the markers, else one with `.git`, else the file's directory.
    public func root(of path: String) -> String {
        var dir = path.deletingLastPathComponent
        var gitRoot: String?
        let fm = FileManager.default
        while !dir.isEmpty, dir != "/" {
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for marker in rootMarkers {
                if marker.hasPrefix("*") {
                    if names.contains(where: { $0.hasSuffix(String(marker.dropFirst())) }) { return dir }
                } else if names.contains(marker) {
                    return dir
                }
            }
            if gitRoot == nil, VCS.markers.contains(where: { names.contains($0.directory) }) { gitRoot = dir }
            dir = dir.deletingLastPathComponent
        }
        return gitRoot ?? path.deletingLastPathComponent
    }
}

/// What a language server says about a place in a text block.
public struct Diagnostic: Codable, Equatable, Sendable {
    public var range: TextRange
    /// 1 error, 2 warning, 3 information, 4 hint.
    public var severity: Int
    public var message: String
    public var source: String?

    public init(range: TextRange, severity: Int, message: String, source: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }
}

/// A place in a file on a host, as a server points to it (line and
/// character from 0, the character in UTF-16 units).
public struct LSPLocation: Codable, Equatable, Sendable {
    public var path: String
    public var line: Int
    public var character: Int
    public var endLine: Int
    public var endCharacter: Int

    public init(path: String, line: Int, character: Int, endLine: Int, endCharacter: Int) {
        self.path = path
        self.line = line
        self.character = character
        self.endLine = endLine
        self.endCharacter = endCharacter
    }
}

/// Edits to a file, in bytes of its text as it is (on the host, or in the
/// block, which are the same when the block is clean).
public struct LSPFileEdit: Codable, Equatable, Sendable {
    public var path: String
    public var edits: [TextEdit]

    public init(path: String, edits: [TextEdit]) {
        self.path = path
        self.edits = edits
    }
}

public struct Completion: Codable, Equatable, Sendable {
    public var label: String
    /// What to put in, in place of the word being typed.
    public var insert: String
    public var detail: String?
    /// LSP's kind: 2 method, 3 function, 5 field, 6 variable, 7 class, ...
    public var kind: Int

    public init(label: String, insert: String, detail: String?, kind: Int) {
        self.label = label
        self.insert = insert
        self.detail = detail
        self.kind = kind
    }
}

/// What the editor asks a language server, through the block's host.
public enum LSPRequest: Codable, Sendable {
    case definition(BlockID, offset: Int)
    case references(BlockID, offset: Int)
    case hover(BlockID, offset: Int)
    case rename(BlockID, offset: Int, newName: String)
    case format(BlockID, tabSize: Int)
    case completion(BlockID, offset: Int)
    /// Where in the text there's something to go to (a type, a function,
    /// a variable…), as the server's semantic tokens say: what ⌘ shows
    /// as links.
    case navigable(BlockID)
    /// What the text declares (its types, functions…), for its outline.
    case symbols(BlockID)
}

public enum LSPResult: Codable, Sendable {
    case locations([LSPLocation])
    /// Byte ranges of the text.
    case ranges([TextRange])
    case hover(String)
    case edits([LSPFileEdit])
    case completions([Completion])
    case symbols([LSPSymbol])
    case none
    case error(String)
}

extension Rope {
    /// A server's position for a byte offset.
    public func lspPosition(ofByte offset: Int) -> (line: Int, character: Int) {
        let n = line(at: offset)
        let start = self.offset(ofLine: n)
        let units = Rope.utf16Count(bytes(in: TextRange(start, max(start, min(offset, count)))))
        return (n, units)
    }

    /// The byte offset of a server's position.
    public func byteOffset(line: Int, character: Int) -> Int {
        guard line < lineCount else { return count }
        let n = max(line, 0)
        let r = lineRange(n)
        let text = self[r]
        let utf16 = text.utf16
        guard let i = utf16.index(utf16.startIndex, offsetBy: character, limitedBy: utf16.endIndex) else { return r.end }
        return r.start + text.utf8.distance(from: text.utf8.startIndex, to: i)
    }
}

/// A name a text declares, as its language server says — a type, a
/// function, a method — for its outline (§7.5).
public struct LSPSymbol: Codable, Equatable, Sendable {
    public var name: String
    /// LSP's SymbolKind: 5 class, 6 method, 12 function, 23 struct…
    public var kind: Int
    /// The line its name is on (0-based), and how deep it is among them.
    public var line: Int
    public var level: Int

    public init(name: String, kind: Int, line: Int, level: Int) {
        self.name = name
        self.kind = kind
        self.line = line
        self.level = level
    }

    /// The kinds an outline shows: what a text is made of — modules,
    /// types, functions and methods — not its fields, variables and enum
    /// cases, which would bury them.
    public static let outlineKinds: Set<Int> = [2, 3, 4, 5, 6, 9, 10, 11, 12, 23, 25]
    /// Kinds whose insides are their own business (a function's locals).
    static let bodies: Set<Int> = [6, 9, 12]

    /// A word for a kind, beside its name.
    public static func word(_ kind: Int) -> String {
        switch kind {
        case 2: "module"
        case 3: "namespace"
        case 4: "package"
        case 5: "class"
        case 6: "method"
        case 9: "init"
        case 10: "enum"
        case 11: "interface"
        case 12: "func"
        case 23: "struct"
        case 25: "operator"
        default: ""
        }
    }

    /// A `textDocument/documentSymbol` answer as an outline, in the text's
    /// order: nested symbols (DocumentSymbol) a level deeper each, not
    /// into a function's body; flat ones (SymbolInformation) a level
    /// deeper when they're in a container.
    public static func outline(_ value: Any) -> [LSPSymbol] {
        guard let items = value as? [[String: Any]] else { return [] }
        func line(_ range: Any?) -> Int? { ((range as? [String: Any])?["start"] as? [String: Any])?["line"] as? Int }
        var out: [LSPSymbol] = []
        func walk(_ items: [[String: Any]], level: Int) {
            for item in items {
                guard let name = item["name"] as? String, let kind = item["kind"] as? Int else { continue }
                let shown = outlineKinds.contains(kind)
                if shown, let l = line(item["selectionRange"]) ?? line(item["range"]) {
                    out.append(LSPSymbol(name: name, kind: kind, line: l, level: level))
                }
                if !bodies.contains(kind), let children = item["children"] as? [[String: Any]] {
                    walk(children, level: shown ? level + 1 : level)
                }
            }
        }
        if items.first?["location"] != nil {
            // Flat: by where each is, a level in for one in a container.
            for item in items {
                guard let name = item["name"] as? String, let kind = item["kind"] as? Int, outlineKinds.contains(kind),
                      let l = line((item["location"] as? [String: Any])?["range"]) else { continue }
                let inside = !((item["containerName"] as? String) ?? "").isEmpty
                out.append(LSPSymbol(name: name, kind: kind, line: l, level: inside ? 1 : 0))
            }
            out.sort { $0.line < $1.line }
        } else {
            walk(items, level: 0)
        }
        return out
    }
}

/// A language server's semantic tokens: what kind of thing each name in a
/// text is, for what ⌘ shows as links.
public enum SemanticTokens {
    /// The token types there's something to go to for: names, as opposed
    /// to keywords, strings, numbers, comments and operators.
    public static let navigableTypes: Set<String> = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable",
        "property", "enumMember", "event", "function", "method", "macro", "decorator",
    ]

    /// Tokens (five numbers each, relative to the one before: line, start,
    /// length — in UTF-16 — type, modifiers) as byte ranges of the names
    /// among them, by the server's legend of types.
    public static func navigable(_ data: [Int], legend: [String], in text: Rope) -> [TextRange] {
        var out: [TextRange] = []
        var line = 0, start = 0
        var i = 0
        while i + 4 < data.count {
            let dLine = data[i], dStart = data[i + 1], length = data[i + 2], type = data[i + 3]
            line += dLine
            start = dLine == 0 ? start + dStart : dStart
            if type >= 0, type < legend.count, navigableTypes.contains(legend[type]) {
                let a = text.byteOffset(line: line, character: start), b = text.byteOffset(line: line, character: start + length)
                if b > a { out.append(TextRange(a, b)) }
            }
            i += 5
        }
        return out
    }
}
