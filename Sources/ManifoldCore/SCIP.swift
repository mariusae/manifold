import Foundation

/// SCIP indexes (DESIGN §2.5): a project's symbols, where each is defined
/// and every place it's used, across its files, under names that stay the
/// same as the code moves (`rust-analyzer cargo manifold 0.1.0 store/Store#put().`)
/// — what a language server says only of one file at a time, while it
/// runs. Made by each language's indexer (`SCIPIndexer`) on the host, as
/// Sourcegraph's protobuf (`scip.proto`), read here.
public struct SCIPIndex: Sendable {
    public struct Occurrence: Sendable, Equatable {
        public var line: Int
        public var character: Int
        public var endLine: Int
        public var endCharacter: Int
        public var symbol: String
        public var roles: Int

        public var isDefinition: Bool { roles & 1 != 0 }

        public init(line: Int, character: Int, endLine: Int, endCharacter: Int, symbol: String, roles: Int) {
            self.line = line
            self.character = character
            self.endLine = endLine
            self.endCharacter = endCharacter
            self.symbol = symbol
            self.roles = roles
        }

        func contains(line l: Int, character c: Int) -> Bool {
            (l, c) >= (line, character) && (l, c) <= (endLine, endCharacter)
        }
    }

    public struct Document: Sendable {
        public var path: String
        public var language: String
        public var occurrences: [Occurrence]
        /// The symbols it defines, as the indexer describes them.
        public var symbols: [String: Information]
        /// What its characters count: 1 UTF-8 bytes, 2 UTF-16 units (and
        /// unsaid, 0, taken as UTF-16), 3 UTF-32.
        public var encoding: Int = 0
    }

    public struct Information: Sendable, Equatable {
        public var symbol: String
        public var documentation: [String]
        public var displayName: String
        public var kind: Int
        public var enclosing: String
    }

    /// Its documents, by path relative to the project's root.
    public private(set) var documents: [String: Document] = [:]
    /// Every symbol's information, wherever it's given.
    public private(set) var information: [String: Information] = [:]
    /// Where each symbol is defined, and used (built as the index is read).
    private var definitions: [String: [(path: String, Occurrence)]] = [:]
    private var uses: [String: [(path: String, Occurrence)]] = [:]

    public init() {}

    // MARK: Reading

    /// An index from its file's bytes (`index.scip`).
    public static func read(_ data: Data) throws -> SCIPIndex {
        var index = SCIPIndex()
        var r = Protobuf(data)
        while let (field, wire) = try r.key() {
            switch (field, wire) {
            case (2, 2): index.add(try readDocument(Protobuf(try r.bytes())))
            case (3, 2):
                let info = try readInformation(Protobuf(try r.bytes()))
                index.information[info.symbol] = info
            default: try r.skip(wire)
            }
        }
        return index
    }

    private mutating func add(_ d: Document) {
        documents[d.path] = d
        for (s, info) in d.symbols { information[s] = info }
        for o in d.occurrences where !o.symbol.hasPrefix("local ") {
            if o.isDefinition { definitions[o.symbol, default: []].append((d.path, o)) }
            uses[o.symbol, default: []].append((d.path, o))
        }
    }

    private static func readDocument(_ data: Protobuf) throws -> Document {
        var r = data
        var d = Document(path: "", language: "", occurrences: [], symbols: [:])
        while let (field, wire) = try r.key() {
            switch (field, wire) {
            case (1, 2): d.path = try r.string()
            case (2, 2): if let o = try readOccurrence(Protobuf(try r.bytes())) { d.occurrences.append(o) }
            case (3, 2):
                let info = try readInformation(Protobuf(try r.bytes()))
                d.symbols[info.symbol] = info
            case (4, 2): d.language = try r.string()
            case (6, 0): d.encoding = Int(try r.varint())
            default: try r.skip(wire)
            }
        }
        return d
    }

    private static func readOccurrence(_ data: Protobuf) throws -> Occurrence? {
        var r = data
        var range: [Int] = [], symbol = "", roles = 0
        while let (field, wire) = try r.key() {
            switch (field, wire) {
            case (1, 2):
                var packed = Protobuf(try r.bytes())
                while !packed.atEnd { range.append(Int(Int32(truncatingIfNeeded: try packed.varint()))) }
            case (1, 0): range.append(Int(Int32(truncatingIfNeeded: try r.varint())))
            case (2, 2): symbol = try r.string()
            case (3, 0): roles = Int(try r.varint())
            default: try r.skip(wire)
            }
        }
        guard !symbol.isEmpty else { return nil }
        // [line, start, end] on one line, or [line, start, endLine, end].
        switch range.count {
        case 3: return Occurrence(line: range[0], character: range[1], endLine: range[0], endCharacter: range[2], symbol: symbol, roles: roles)
        case 4: return Occurrence(line: range[0], character: range[1], endLine: range[2], endCharacter: range[3], symbol: symbol, roles: roles)
        default: return nil
        }
    }

    private static func readInformation(_ data: Protobuf) throws -> Information {
        var r = data
        var info = Information(symbol: "", documentation: [], displayName: "", kind: 0, enclosing: "")
        while let (field, wire) = try r.key() {
            switch (field, wire) {
            case (1, 2): info.symbol = try r.string()
            case (3, 2): info.documentation.append(try r.string())
            case (5, 0): info.kind = Int(try r.varint())
            case (6, 2): info.displayName = try r.string()
            case (8, 2): info.enclosing = try r.string()
            default: try r.skip(wire)
            }
        }
        return info
    }

    // MARK: Asking

    /// The symbol at a place in a file (relative path; line and character
    /// from 0): the innermost occurrence there.
    public func symbol(at path: String, line: Int, character: Int) -> String? {
        documents[path]?.occurrences.filter { $0.contains(line: line, character: character) && !$0.symbol.hasPrefix("local ") }
            .min { ($0.endLine - $0.line, $0.endCharacter - $0.character) < ($1.endLine - $1.line, $1.endCharacter - $1.character) }?.symbol
    }

    public func definitions(of symbol: String) -> [(path: String, occurrence: Occurrence)] { definitions[symbol] ?? [] }

    /// Every place it's used (its definitions among them), in order.
    public func references(to symbol: String) -> [(path: String, occurrence: Occurrence)] {
        (uses[symbol] ?? []).sorted { ($0.path, $0.1.line, $0.1.character) < ($1.path, $1.1.line, $1.1.character) }
    }

    /// What a file defines, in order.
    public func defined(in path: String) -> [Occurrence] {
        documents[path]?.occurrences.filter { $0.isDefinition && !$0.symbol.hasPrefix("local ") }.sorted { ($0.line, $0.character) < ($1.line, $1.character) } ?? []
    }

    /// What can be found by name (§2.6): each symbol defined in the
    /// project — not locals, parameters or meta — with its own name, what
    /// it's in and its kind, where it's defined; made once, asked often.
    public func searchable() -> [Searchable] {
        definitions.compactMap { symbol, defs in
            guard let kind = SymbolHit.kind(scip: symbol), let (path, o) = defs.first else { return nil }
            let full = name(of: symbol)
            var name = full, container = ""
            if information[symbol]?.displayName.isEmpty ?? true, let dot = full.lastIndex(of: ".") {
                name = String(full[full.index(after: dot)...])
                container = String(full[..<dot])
            } else {
                let qualified = Self.descriptorName(symbol)
                if let dot = qualified.lastIndex(of: ".") { container = String(qualified[..<dot]) }
            }
            return Searchable(symbol: symbol, name: name, container: container, kind: kind, path: path, occurrence: o)
        }
    }

    public struct Searchable: Sendable {
        public var symbol: String
        public var name: String
        public var container: String
        public var kind: String
        public var path: String
        public var occurrence: Occurrence
    }

    /// A symbol's name to show: the indexer's, else its last descriptor's
    /// words (`store/Store#put().` → `Store.put`).
    public func name(of symbol: String) -> String {
        if let n = information[symbol]?.displayName, !n.isEmpty { return n }
        return Self.descriptorName(symbol)
    }

    public static func descriptorName(_ symbol: String) -> String {
        // scheme manager package version descriptors…: the descriptors
        // after the fourth space (spaces in names are doubled).
        var spaces = 0, i = symbol.startIndex
        while i < symbol.endIndex, spaces < 4 {
            if symbol[i] == " " { spaces += 1 }
            i = symbol.index(after: i)
        }
        let descriptors = symbol[i...]
        var parts: [String] = [], word = ""
        for c in descriptors {
            switch c {
            case "/", "#", ".", ":", "!":
                if !word.isEmpty { parts.append(word) }
                word = ""
            case "(", ")", "[", "]", "`":
                if c == "(" , !word.isEmpty { parts.append(word); word = "" }
            default: word.append(c)
            }
        }
        if !word.isEmpty { parts.append(word) }
        // The type and its member, not the package path.
        return parts.suffix(2).joined(separator: ".")
    }
}

/// A protobuf message's fields, read one at a time.
struct Protobuf {
    struct Malformed: Error {}
    private let data: Data
    private var at: Data.Index

    init(_ data: Data) {
        self.data = data
        at = data.startIndex
    }

    var atEnd: Bool { at >= data.endIndex }

    mutating func varint() throws -> UInt64 {
        var out: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard at < data.endIndex, shift < 64 else { throw Malformed() }
            let b = data[at]
            at += 1
            out |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return out }
            shift += 7
        }
    }

    /// The next field's number and wire type; nil at the end.
    mutating func key() throws -> (Int, Int)? {
        guard !atEnd else { return nil }
        let k = try varint()
        return (Int(k >> 3), Int(k & 7))
    }

    mutating func bytes() throws -> Data {
        let n = Int(try varint())
        guard n >= 0, at + n <= data.endIndex else { throw Malformed() }
        let out = data[at..<(at + n)]
        at += n
        return out
    }

    mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: at += 8
        case 2: _ = try bytes()
        case 5: at += 4
        default: throw Malformed()
        }
        if at > data.endIndex { throw Malformed() }
    }
}

// MARK: Indexers

/// An indexer that makes a project's SCIP index (§2.5), as each host runs
/// it: for which languages, how its project's root is found, and its
/// command — run in the root with `{out}` the index's file and `{name}`
/// the root's folder's name.
public struct SCIPIndexer: Codable, Equatable, Sendable {
    public var id: String
    public var languages: [String]
    public var rootMarkers: [String]
    public var command: String

    public static let defaults: [SCIPIndexer] = [
        SCIPIndexer(id: "rust", languages: ["rust"], rootMarkers: ["Cargo.toml"],
                    command: "rust-analyzer scip . --output {out}"),
        SCIPIndexer(id: "typescript", languages: ["typescript", "tsx", "javascript"], rootMarkers: ["tsconfig.json", "package.json"],
                    command: "npx --yes @sourcegraph/scip-typescript index --infer-tsconfig --output {out}"),
        SCIPIndexer(id: "python", languages: ["python"], rootMarkers: ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"],
                    command: "npx --yes @sourcegraph/scip-python index . --project-name {name} --output {out}"),
        SCIPIndexer(id: "go", languages: ["go"], rootMarkers: ["go.mod"],
                    command: "scip-go --output {out}"),
        SCIPIndexer(id: "c", languages: ["c", "cpp", "objc"], rootMarkers: ["compile_commands.json"],
                    command: "scip-clang --compdb-path=compile_commands.json --index-output-path={out}"),
        SCIPIndexer(id: "java", languages: ["java", "kotlin", "scala"], rootMarkers: ["pom.xml", "build.gradle", "build.gradle.kts", "build.sbt"],
                    command: "scip-java index --output {out}"),
    ]

    /// The indexer for a file, and its project's root: the nearest folder
    /// up from it with one of the indexer's markers.
    public static func forFile(_ path: String, among indexers: [SCIPIndexer] = defaults) -> (SCIPIndexer, root: String)? {
        guard let language = CodeLanguage.forPath(path)?.id,
              let indexer = indexers.first(where: { $0.languages.contains(language) }) else { return nil }
        var dir = path.deletingLastPathComponent
        let fm = FileManager.default
        while !dir.isEmpty, dir != "/" {
            for marker in indexer.rootMarkers where fm.fileExists(atPath: dir.appendingPathComponent(marker)) { return (indexer, dir) }
            dir = dir.deletingLastPathComponent
        }
        return nil
    }

    /// Its command for a root, writing to `out`.
    public func command(root: String, out: String) -> String {
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return command.replacingOccurrences(of: "{out}", with: quoted(out)).replacingOccurrences(of: "{name}", with: quoted(root.lastPathComponent))
    }
}

/// What's asked of a host's indexes.
public enum SCIPRequest: Codable, Sendable {
    /// The project a file is in indexed (again).
    case index(path: String)
    /// How the index of a file's project stands.
    case status(path: String)
    /// The symbol at a place in a file (line from 0, and the byte in it
    /// from 0 — the host counts it as the index does), with what's said of
    /// it and where it's defined.
    case symbol(path: String, line: Int, byte: Int)
    /// Every place a symbol is used, in the project a file is in.
    case references(symbol: String, path: String)
    /// What a file defines.
    case defined(path: String)
    /// Where a symbol is defined, in the project a file is in.
    case definition(symbol: String, path: String)
}

public enum SCIPResult: Codable, Sendable {
    case status(SCIPStatus)
    case symbol(SCIPSymbol?)
    case locations([SCIPLocation])
    case symbols([SCIPSymbol])
    case error(String)
}

/// A place in a file an index names: its absolute path, where (lines and
/// characters from 0), and the line's words.
public struct SCIPLocation: Codable, Equatable, Sendable {
    public var path: String
    public var line: Int
    public var character: Int
    public var endLine: Int
    public var endCharacter: Int
    public var isDefinition: Bool
    public var text: String

    public init(path: String, line: Int, character: Int, endLine: Int, endCharacter: Int, isDefinition: Bool, text: String) {
        self.path = path
        self.line = line
        self.character = character
        self.endLine = endLine
        self.endCharacter = endCharacter
        self.isDefinition = isDefinition
        self.text = text
    }
}

/// A symbol, as an index knows it.
public struct SCIPSymbol: Codable, Equatable, Sendable {
    public var symbol: String
    public var name: String
    public var documentation: String
    public var definition: SCIPLocation?

    public init(symbol: String, name: String, documentation: String, definition: SCIPLocation?) {
        self.symbol = symbol
        self.name = name
        self.documentation = documentation
        self.definition = definition
    }
}

/// How a project's index stands.
public struct SCIPStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case none, indexing, current, failed }
    public var root: String?
    public var indexer: String?
    public var state: State
    /// When it was made; why it failed (the indexer's last words).
    public var at: Date?
    public var message: String?

    public init(root: String?, indexer: String?, state: State, at: Date? = nil, message: String? = nil) {
        self.root = root
        self.indexer = indexer
        self.state = state
        self.at = at
        self.message = message
    }
}
