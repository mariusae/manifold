import Foundation
import ManifoldCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Language servers, run on this host for the files here (DESIGN.md
/// §7.1): one per language and workspace root, started when a file of
/// theirs is opened, fed the block's text as it changes (whole, each
/// time, a moment after the last change), and asked what the editor
/// wants to know. Diagnostics go to every client.
final class LanguageServers {
    private let queue: DispatchQueue
    private var configs = LanguageServerConfig.defaults
    private var servers: [String: LanguageServer] = [:]
    /// Which server has which block open, and the version it has.
    private var opened: [BlockID: (server: String, version: Int)] = [:]
    private var pending: [BlockID: DispatchWorkItem] = [:]
    /// Text the server was last given, by path, for turning its positions
    /// into bytes of files that aren't blocks.
    var textOf: (BlockID) -> (text: Rope, path: String?)? = { _ in nil }
    var onDiagnostics: ((BlockID, [Diagnostic]) -> Void)?
    var onState: ((String, String, String) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func configure(_ configs: [LanguageServerConfig]) {
        guard configs != self.configs else { return }
        self.configs = configs
        // Servers whose command changed are started afresh next time.
        for (key, server) in servers where configs.first(where: { $0.id == server.language })?.command != server.command {
            server.stop()
            servers.removeValue(forKey: key)
            opened = opened.filter { $0.value.server != key }
        }
    }

    /// The server for a block's file, started if need be.
    private func server(for block: BlockID) -> LanguageServer? {
        guard let (_, path) = textOf(block), let path, let lang = LanguageServerConfig.language(for: path, in: configs) else { return nil }
        let root = lang.root(of: path)
        let key = lang.id + "|" + root
        if let s = servers[key] { return s.failed ? nil : s }
        let s = LanguageServer(language: lang.id, command: lang.command, root: root, queue: queue)
        s.onDiagnostics = { [weak self] path, items in self?.diagnostics(path: path, items) }
        s.onState = { [weak self] state in self?.onState?(lang.id, root, state) }
        servers[key] = s
        s.start()
        return s
    }

    /// A text block opened, or changed, or saved: its server hears, a
    /// moment after the last change.
    func textChanged(_ block: BlockID, saved: Bool = false) {
        pending[block]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sync(block, saved: saved) }
        pending[block] = work
        queue.asyncAfter(deadline: .now() + (saved ? 0 : 0.2), execute: work)
    }

    /// The blocks placed somewhere: each is open with its server (if its
    /// language has one) while it is, and closed when it's not.
    func setOpen(_ ids: Set<BlockID>) {
        for block in ids where opened[block] == nil && pending[block] == nil {
            textChanged(block)
        }
        for (block, o) in opened where !ids.contains(block) {
            if let path = textOf(block)?.path, let server = servers[o.server] {
                server.notify("textDocument/didClose", ["textDocument": ["uri": Self.uri(path)]])
            }
            opened.removeValue(forKey: block)
            pending[block]?.cancel()
            pending.removeValue(forKey: block)
        }
    }

    private func sync(_ block: BlockID, saved: Bool) {
        guard let (text, path) = textOf(block), let path, let server = server(for: block) else { return }
        let uri = Self.uri(path)
        if let o = opened[block], o.server == server.key {
            let version = o.version + 1
            opened[block] = (server.key, version)
            server.notify("textDocument/didChange", [
                "textDocument": ["uri": uri, "version": version],
                "contentChanges": [["text": text.string]],
            ])
        } else {
            opened[block] = (server.key, 1)
            server.notify("textDocument/didOpen", [
                "textDocument": ["uri": uri, "languageId": server.language, "version": 1, "text": text.string],
            ])
        }
        if saved {
            server.notify("textDocument/didSave", ["textDocument": ["uri": uri]])
        }
    }

    /// The open block whose file a server's path names, if any: paths are
    /// compared as the file system resolves them (/tmp and /private/tmp).
    private func openBlock(at path: String) -> BlockID? {
        let wanted = Self.canonical(path)
        return opened.keys.first { block in
            guard let p = textOf(block)?.path else { return false }
            return p == path || Self.canonical(p) == wanted
        }
    }

    /// A server's path, as the block it's open as has it.
    private func blockPath(_ path: String) -> String {
        openBlock(at: path).flatMap { textOf($0)?.path } ?? path
    }

    static func canonical(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    private func diagnostics(path: String, _ items: [[String: Any]]) {
        // The block for the path, with the text to place them in.
        guard let block = openBlock(at: path) else { return }
        guard let (text, _) = textOf(block) else { return }
        let out: [Diagnostic] = items.compactMap { d in
            guard let range = d["range"] as? [String: Any], let message = d["message"] as? String else { return nil }
            let r = Self.range(range, in: text)
            return Diagnostic(range: r, severity: (d["severity"] as? Int) ?? 1, message: message, source: d["source"] as? String)
        }
        onDiagnostics?(block, out)
    }

    // MARK: Requests

    func request(_ request: LSPRequest, done: @escaping (LSPResult) -> Void) {
        let block: BlockID
        switch request {
        case let .definition(b, _), let .references(b, _), let .hover(b, _), let .rename(b, _, _), let .format(b, _), let .completion(b, _):
            block = b
        }
        guard let (text, path) = textOf(block), let path else { return done(.error("not a file")) }
        guard let server = server(for: block) else { return done(.error("no language server for \(path.lastPathComponent)")) }
        if opened[block] == nil { sync(block, saved: false) }
        let uri = Self.uri(path)
        func position(_ offset: Int) -> [String: Any] {
            let p = text.lspPosition(ofByte: offset)
            return ["line": p.line, "character": p.character]
        }
        switch request {
        case let .definition(_, offset):
            server.request("textDocument/definition", ["textDocument": ["uri": uri], "position": position(offset)]) { [weak self] result in
                done(.locations(self?.locations(result) ?? []))
            }
        case let .references(_, offset):
            server.request("textDocument/references", ["textDocument": ["uri": uri], "position": position(offset),
                                                       "context": ["includeDeclaration": true]]) { [weak self] result in
                done(.locations(self?.locations(result) ?? []))
            }
        case let .hover(_, offset):
            server.request("textDocument/hover", ["textDocument": ["uri": uri], "position": position(offset)]) { result in
                guard case .success(let value) = result, let dict = value as? [String: Any] else { return done(.none) }
                done(.hover(Self.markup(dict["contents"])))
            }
        case let .rename(_, offset, newName):
            server.request("textDocument/rename", ["textDocument": ["uri": uri], "position": position(offset), "newName": newName]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let value): done(.edits(self.workspaceEdits(value)))
                case .failure(let e): done(.error(e.message))
                }
            }
        case let .format(_, tabSize):
            server.request("textDocument/formatting", ["textDocument": ["uri": uri], "options": ["tabSize": tabSize, "insertSpaces": true]]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let value):
                    let edits = (value as? [[String: Any]]) ?? []
                    done(.edits([LSPFileEdit(path: path, edits: self.textEdits(edits, in: text))]))
                case .failure(let e): done(.error(e.message))
                }
            }
        case let .completion(_, offset):
            server.request("textDocument/completion", ["textDocument": ["uri": uri], "position": position(offset)]) { result in
                guard case .success(let value) = result else { return done(.completions([])) }
                var items = (value as? [String: Any])?["items"] as? [[String: Any]] ?? (value as? [[String: Any]]) ?? []
                // Servers answer with everything in scope; what's been
                // typed of the word narrows it before it travels.
                let typed = Self.wordPrefix(in: text, before: offset).lowercased()
                if !typed.isEmpty {
                    func key(_ item: [String: Any]) -> String { ((item["filterText"] as? String) ?? (item["label"] as? String) ?? "").lowercased() }
                    items = items.filter { key($0).contains(typed) }
                    items.sort { a, b in
                        let ap = key(a).hasPrefix(typed), bp = key(b).hasPrefix(typed)
                        return ap != bp ? ap : key(a).count < key(b).count
                    }
                }
                let out: [Completion] = items.prefix(80).compactMap { item in
                    guard let label = item["label"] as? String else { return nil }
                    var insert = (item["insertText"] as? String) ?? label
                    if let te = item["textEdit"] as? [String: Any], let t = te["newText"] as? String { insert = t }
                    // Snippets: the placeholders are dropped.
                    if (item["insertTextFormat"] as? Int) == 2 { insert = Self.plain(snippet: insert) }
                    return Completion(label: label, insert: insert, detail: item["detail"] as? String, kind: (item["kind"] as? Int) ?? 0)
                }
                done(.completions(out))
            }
        }
    }

    /// A workspace edit's changes, per file, as bytes of each file's text.
    private func workspaceEdits(_ value: Any) -> [LSPFileEdit] {
        guard let dict = value as? [String: Any] else { return [] }
        var byURI: [String: [[String: Any]]] = [:]
        if let changes = dict["changes"] as? [String: [[String: Any]]] {
            byURI = changes
        } else if let docs = dict["documentChanges"] as? [[String: Any]] {
            for d in docs {
                guard let td = d["textDocument"] as? [String: Any], let uri = td["uri"] as? String, let edits = d["edits"] as? [[String: Any]] else { continue }
                byURI[uri, default: []].append(contentsOf: edits)
            }
        }
        var out: [LSPFileEdit] = []
        for (uri, edits) in byURI {
            guard let path = Self.path(uri).map(blockPath) else { continue }
            let text: Rope
            if let block = openBlock(at: path), let t = textOf(block)?.text {
                text = t
            } else if let contents = TextFile.read(path) {
                text = Rope(contents.text)
            } else {
                continue
            }
            out.append(LSPFileEdit(path: path, edits: textEdits(edits, in: text)))
        }
        return out
    }

    private func textEdits(_ edits: [[String: Any]], in text: Rope) -> [TextEdit] {
        edits.compactMap { e in
            guard let range = e["range"] as? [String: Any], let newText = e["newText"] as? String else { return nil }
            let r = Self.range(range, in: text)
            return TextEdit(start: r.start, end: r.end, text: newText)
        }
    }

    /// The identifier characters just before an offset.
    static func wordPrefix(in text: Rope, before offset: Int) -> String {
        var start = min(offset, text.count)
        while start > 0, let b = text.byte(at: start - 1),
              b == 0x5F || (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b >= 0x80 {
            start -= 1
        }
        return text[ManifoldCore.TextRange(start, min(offset, text.count))]
    }

    // MARK: Conversions

    static func uri(_ path: String) -> String {
        "file://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }

    static func path(_ uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }
        return String(uri.dropFirst(7)).removingPercentEncoding
    }

    static func range(_ range: [String: Any], in text: Rope) -> ManifoldCore.TextRange {
        guard let start = range["start"] as? [String: Any], let end = range["end"] as? [String: Any] else { return ManifoldCore.TextRange(0, 0) }
        let s = text.byteOffset(line: (start["line"] as? Int) ?? 0, character: (start["character"] as? Int) ?? 0)
        let e = text.byteOffset(line: (end["line"] as? Int) ?? 0, character: (end["character"] as? Int) ?? 0)
        return ManifoldCore.TextRange(s, e)
    }

    func locations(_ result: Result<Any, RPCError>) -> [LSPLocation] {
        guard case .success(let value) = result else { return [] }
        let items: [[String: Any]]
        if let one = value as? [String: Any] { items = [one] } else { items = (value as? [[String: Any]]) ?? [] }
        return items.compactMap { item in
            let uri = (item["uri"] as? String) ?? (item["targetUri"] as? String)
            let range = (item["range"] as? [String: Any]) ?? (item["targetSelectionRange"] as? [String: Any]) ?? (item["targetRange"] as? [String: Any])
            guard let uri, let path = Self.path(uri).map(blockPath), let range,
                  let start = range["start"] as? [String: Any], let end = range["end"] as? [String: Any] else { return nil }
            return LSPLocation(path: path, line: (start["line"] as? Int) ?? 0, character: (start["character"] as? Int) ?? 0,
                               endLine: (end["line"] as? Int) ?? 0, endCharacter: (end["character"] as? Int) ?? 0)
        }
    }

    static func markup(_ contents: Any?) -> String {
        if let s = contents as? String { return s }
        if let dict = contents as? [String: Any], let v = dict["value"] as? String { return v }
        if let list = contents as? [Any] { return list.map { markup($0) }.joined(separator: "\n\n") }
        return ""
    }

    static func plain(snippet: String) -> String {
        // $1, ${1:placeholder}, $0 → the placeholder's text, or nothing.
        var out = ""
        var i = snippet.startIndex
        while i < snippet.endIndex {
            let c = snippet[i]
            if c == "\\", snippet.index(after: i) < snippet.endIndex {
                out.append(snippet[snippet.index(after: i)])
                i = snippet.index(i, offsetBy: 2)
            } else if c == "$" {
                let next = snippet.index(after: i)
                if next < snippet.endIndex, snippet[next] == "{", let close = snippet[next...].firstIndex(of: "}") {
                    let inner = snippet[snippet.index(after: next)..<close]
                    if let colon = inner.firstIndex(of: ":") { out += inner[inner.index(after: colon)...] }
                    i = snippet.index(after: close)
                } else {
                    var j = next
                    while j < snippet.endIndex, snippet[j].isNumber { j = snippet.index(after: j) }
                    i = j
                }
            } else {
                out.append(c)
                i = snippet.index(after: i)
            }
        }
        return out
    }

    func stopAll() {
        for s in servers.values { s.stop() }
    }
}

private func sysRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int) -> Int { read(fd, buf, n) }

struct RPCError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// One language server process, spoken to in JSON-RPC over its stdio.
final class LanguageServer {
    let language: String
    let command: String
    let root: String
    var key: String { language + "|" + root }
    private let queue: DispatchQueue
    private var child: Child?
    private var nextID = 1
    private var waiting: [Int: (Result<Any, RPCError>) -> Void] = [:]
    private(set) var ready = false
    private(set) var failed = false
    private var queued: [(String, [String: Any])] = []
    var onDiagnostics: ((String, [[String: Any]]) -> Void)?
    var onState: ((String) -> Void)?

    init(language: String, command: String, root: String, queue: DispatchQueue) {
        self.language = language
        self.command = command
        self.root = root
        self.queue = queue
    }

    func start() {
        let argv = ["/bin/sh", "-c", "cd '\(root)' && exec \(command)"]
        guard let child = try? Child.spawn(argv, stderrToNull: true) else {
            failed = true
            onState?("couldn't start")
            return
        }
        self.child = child
        onState?("starting")
        let reader = Thread { [weak self] in self?.read(child.output) }
        reader.start()
        request("initialize", [
            "processId": Int(getpid()),
            "rootUri": LanguageServers.uri(root),
            "rootPath": root,
            "workspaceFolders": [["uri": LanguageServers.uri(root), "name": root.lastPathComponent]],
            "capabilities": [
                "textDocument": [
                    "synchronization": ["didSave": true],
                    "hover": ["contentFormat": ["plaintext", "markdown"]],
                    "completion": ["completionItem": ["snippetSupport": true, "insertReplaceSupport": false]],
                    "publishDiagnostics": ["relatedInformation": false],
                    "rename": ["prepareSupport": false],
                ],
                "workspace": ["workspaceEdit": ["documentChanges": true], "workspaceFolders": true],
            ],
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.notify("initialized", [:])
                self.ready = true
                self.onState?("ready")
                for (method, params) in self.queued { self.send(["method": method, "params": params]) }
                self.queued = []
            case .failure(let e):
                self.failed = true
                self.onState?("failed: \(e.message)")
            }
        }
    }

    func stop() {
        guard let child else { return }
        request("shutdown", [:]) { [weak self] _ in self?.notify("exit", [:]) }
        queue.asyncAfter(deadline: .now() + 2) { kill(child.pid, SIGTERM) }
    }

    func notify(_ method: String, _ params: [String: Any]) {
        guard ready || method == "initialized" else {
            queued.append((method, params))
            return
        }
        send(["method": method, "params": params])
    }

    func request(_ method: String, _ params: [String: Any], done: @escaping (Result<Any, RPCError>) -> Void) {
        guard ready || method == "initialize" else {
            // Before it's ready, the question waits with the notifications.
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if self.failed { done(.failure(RPCError("the language server failed to start"))) } else { self.request(method, params, done: done) }
            }
            return
        }
        let id = nextID
        nextID += 1
        waiting[id] = done
        send(["id": id, "method": method, "params": params])
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            if let w = self?.waiting.removeValue(forKey: id) { w(.failure(RPCError("the language server didn't answer"))) }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let child else { return }
        var m = message
        m["jsonrpc"] = "2.0"
        guard let body = try? JSONSerialization.data(withJSONObject: m) else { return }
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(child.input, raw.baseAddress! + off, raw.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
            }
        }
    }

    /// Reads messages off the server's stdout (on its own thread) and hands
    /// them to the queue.
    private func read(_ fd: Int32) {
        var buffer = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = sysRead(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            buffer.append(contentsOf: buf[0..<n])
            while let message = Self.nextMessage(&buffer) {
                queue.async { [weak self] in self?.handle(message) }
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.failed = true
            self.ready = false
            self.onState?("exited")
            for w in self.waiting.values { w(.failure(RPCError("the language server exited"))) }
            self.waiting = [:]
        }
    }

    private static func nextMessage(_ buffer: inout Data) -> [String: Any]? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var length = 0
        for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = buffer.subdata(in: bodyStart..<bodyStart + length)
        buffer.removeSubrange(buffer.startIndex..<bodyStart + length)
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private func handle(_ message: [String: Any]) {
        if let id = message["id"] as? Int, message["method"] == nil {
            guard let done = waiting.removeValue(forKey: id) else { return }
            if let error = message["error"] as? [String: Any] {
                done(.failure(RPCError((error["message"] as? String) ?? "error")))
            } else {
                done(.success(message["result"] ?? NSNull()))
            }
            return
        }
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "textDocument/publishDiagnostics":
            if let uri = params["uri"] as? String, let path = LanguageServers.path(uri) {
                onDiagnostics?(path, (params["diagnostics"] as? [[String: Any]]) ?? [])
            }
        case "window/showMessage", "window/logMessage":
            if method == "window/showMessage", let text = params["message"] as? String { onState?(text) }
        case "$/progress":
            break
        case "workspace/configuration":
            if let id = message["id"] {
                let items = (params["items"] as? [Any])?.count ?? 1
                send(["id": id, "result": Array(repeating: NSNull(), count: items)])
            }
        case "client/registerCapability", "client/unregisterCapability", "workspace/workspaceFolders":
            if let id = message["id"] { send(["id": id, "result": method == "workspace/workspaceFolders" ? [["uri": LanguageServers.uri(root), "name": root.lastPathComponent]] : NSNull()]) }
        case "window/workDoneProgress/create":
            if let id = message["id"] { send(["id": id, "result": NSNull()]) }
        default:
            if let id = message["id"] {
                send(["id": id, "error": ["code": -32601, "message": "not supported"]])
            }
        }
    }
}
