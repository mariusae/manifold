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
}

public enum LSPResult: Codable, Sendable {
    case locations([LSPLocation])
    case hover(String)
    case edits([LSPFileEdit])
    case completions([Completion])
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
