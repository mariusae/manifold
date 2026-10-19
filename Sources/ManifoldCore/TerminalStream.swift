import Foundation

/// The recent output of a terminal session, replayed into a terminal that
/// attaches to it so it shows what it showed before.
public struct ReplayBuffer: Sendable {
    public let limit: Int
    private var bytes = Data()
    /// Whether the session is on the alternate screen (a full-screen program
    /// like vim or less is running).
    public private(set) var altScreen = false
    private var trimmed = false
    private var tail = [UInt8]()

    public init(limit: Int = 4 << 20) {
        self.limit = limit
    }

    /// A buffer that starts with the output of an earlier session of the
    /// same pane, left in a state a new shell can carry on from.
    public init(limit: Int = 4 << 20, restoring history: Data) {
        self.limit = limit
        guard !history.isEmpty else { return }
        append(history)
        var tail = "\u{1b}[0m"
        if altScreen { tail += "\u{1b}[?1049l" }
        append(Data((tail + "\r\n").utf8))
    }

    /// The buffered output, for saving.
    public var contents: Data { bytes }

    public mutating func append(_ data: Data) {
        scanModes(data)
        bytes.append(data)
        if bytes.count > limit {
            // Cut at a line break, so the replay doesn't start in the middle
            // of an escape sequence.
            var cut = bytes.startIndex + bytes.count - limit * 3 / 4
            if let nl = bytes[cut...].firstIndex(of: 0x0A) { cut = nl + 1 }
            bytes.removeSubrange(bytes.startIndex..<cut)
            bytes = Data(bytes)
            trimmed = true
        }
    }

    /// What to send an attaching terminal.
    public var replay: Data {
        var out = Data()
        // Start from a clean terminal: the attaching one may already have
        // shown some of this.
        out.append(contentsOf: Array("\u{1b}[?1049l\u{1b}c".utf8))
        if trimmed && altScreen {
            // The switch to the alternate screen was trimmed away.
            out.append(contentsOf: Array("\u{1b}[?1049h".utf8))
        }
        out.append(bytes)
        return out
    }

    private static let modes: [(String, Bool)] = [
        ("\u{1b}[?1049h", true), ("\u{1b}[?1049l", false),
        ("\u{1b}[?1047h", true), ("\u{1b}[?1047l", false),
        ("\u{1b}[?47h", true), ("\u{1b}[?47l", false),
    ].map { ($0.0, $0.1) }

    private mutating func scanModes(_ data: Data) {
        // Include the end of the last chunk, for sequences split across two.
        let hay = tail + [UInt8](data)
        var last: (Int, Bool)?
        for (seq, on) in Self.modes {
            let needle = Array(seq.utf8)
            if let r = lastRange(of: needle, in: hay), r > (last?.0 ?? -1) {
                last = (r, on)
            }
        }
        if let last { altScreen = last.1 }
        tail = Array(hay.suffix(8))
    }

    private func lastRange(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            if hay[i] == needle[0] && Array(hay[i..<i + needle.count]) == needle { return i }
            i -= 1
        }
        return nil
    }
}

/// Picks window titles (OSC 0 and OSC 2) out of a terminal's output.
public struct TitleScanner: Sendable {
    private enum State { case ground, esc, osc, oscEsc }
    private var state = State.ground
    private var osc = [UInt8]()

    public init() {}

    /// Feeds output; returns the last title set in it, if any.
    public mutating func feed(_ data: Data) -> String? {
        var title: String?
        for b in data {
            switch state {
            case .ground:
                if b == 0x1B { state = .esc }
            case .esc:
                if b == 0x5D { // ]
                    state = .osc
                    osc.removeAll(keepingCapacity: true)
                } else {
                    state = b == 0x1B ? .esc : .ground
                }
            case .osc:
                if b == 0x07 {
                    title = finish() ?? title
                    state = .ground
                } else if b == 0x1B {
                    state = .oscEsc
                } else if osc.count < 4096 {
                    osc.append(b)
                }
            case .oscEsc:
                if b == 0x5C { // ESC \ ends it
                    title = finish() ?? title
                    state = .ground
                } else {
                    // Anything else aborts the OSC and starts a new escape.
                    state = b == 0x5D ? .osc : .ground
                    osc.removeAll(keepingCapacity: true)
                }
            }
        }
        return title
    }

    private func finish() -> String? {
        guard let semi = osc.firstIndex(of: 0x3B) else { return nil }
        let code = String(decoding: osc[..<semi], as: UTF8.self)
        guard code == "0" || code == "2" else { return nil }
        return String(decoding: osc[(semi + 1)...], as: UTF8.self)
    }
}

// MARK: Program status (§3.7)

/// What a terminal's output says about its program's status: OSC 7501
/// reports, OSC 9;4 progress, and OSC 133 prompt marks.
public enum StatusSignal: Equatable, Sendable {
    /// A 7501 report for a record (the root when `id` is empty).
    case report(id: String, state: StatusState, kind: BlockedKind?, progress: Int?, app: String?, title: String?, msg: String?)
    /// `state=clear`: the record and its children, or everything with no id.
    case clear(id: String?)
    /// OSC 9;4: ConEmu progress, as other terminals draw it.
    case progress(ProgressState, percent: Int?)
    /// OSC 133 A: a new shell prompt.
    case prompt
    /// `OSC 7502 ; <line> ST`: the shell is about to run a command, as
    /// Manifold's shell hooks say (§3.8).
    case command(String)
    /// OSC 133 D: the command ended, with its status if the shell says.
    case commandEnded(status: Int32?)
    /// OSC 7: the shell's working directory, and the host it says it's
    /// on (empty for none): `file://host/path`, percent-encoded, or
    /// kitty's `kitty-shell-cwd://host/path`, raw.
    case directory(host: String, path: String)
    /// `OSC 7501 ; ? ST`: the program asks whether the terminal speaks
    /// 7501; it expects `queryReply` back on its input before anything
    /// else answers (a device-attributes reply it sent to race it).
    case query

    public enum ProgressState: Sendable { case remove, set, error, indeterminate, pause }

    /// What a terminal that speaks 7501 answers a query with: `?`, and
    /// the states and kinds it takes.
    public static let queryReply = "\u{1B}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1B}\\"
}

/// Finds status signals in a terminal's output, between the bytes the
/// terminal itself draws. The same state machine as `TitleScanner`'s;
/// the two look at the same stream for different sequences.
public struct StatusScanner: Sendable {
    private enum State { case ground, esc, osc, oscEsc }
    private var state = State.ground
    private var osc = [UInt8]()
    /// Whether a 7501 report has ever come: then OSC 9;4 is ignored, as
    /// the spec asks.
    public private(set) var sawReports = false

    public init() {}

    /// Feeds output; returns the signals in it, in order.
    public mutating func feed(_ data: Data) -> [StatusSignal] {
        var out: [StatusSignal] = []
        for b in data {
            switch state {
            case .ground:
                if b == 0x1B { state = .esc }
            case .esc:
                if b == 0x5D {
                    state = .osc
                    osc.removeAll(keepingCapacity: true)
                } else {
                    state = b == 0x1B ? .esc : .ground
                }
            case .osc:
                if b == 0x07 {
                    if let s = finish() { out.append(s) }
                    state = .ground
                } else if b == 0x1B {
                    state = .oscEsc
                } else if osc.count < 4096 {
                    osc.append(b)
                }
            case .oscEsc:
                if b == 0x5C {
                    if let s = finish() { out.append(s) }
                    state = .ground
                } else {
                    state = b == 0x5D ? .osc : .ground
                    osc.removeAll(keepingCapacity: true)
                }
            }
        }
        return out
    }

    private mutating func finish() -> StatusSignal? {
        guard let semi = osc.firstIndex(of: 0x3B) else { return nil }
        let code = String(decoding: osc[..<semi], as: UTF8.self)
        let body = osc[(semi + 1)...]
        switch code {
        case "7501":
            guard let s = Self.parseReport(body) else { return nil }
            if case .query = s { return s }
            sawReports = true
            return s
        case "133":
            switch body.first {
            case UInt8(ascii: "A"): return .prompt
            case UInt8(ascii: "D"):
                let rest = String(decoding: body.dropFirst(), as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
                return .commandEnded(status: rest.count > 1 ? Int32(rest[1]) : nil)
            default: return nil
            }
        case "7":
            return Self.parseDirectory(body)
        case "7502":
            // Control characters can't be in it (the hooks blank them);
            // anything that isn't text is dropped.
            guard body.count <= 4096, let text = String(bytes: body, encoding: .utf8) else { return nil }
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : .command(line)
        case "9":
            guard !sawReports else { return nil }
            // 9;4;st;pct
            let parts = String(decoding: body, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
            guard parts.first == "4", parts.count >= 2, let st = Int(parts[1]) else { return nil }
            let pct = parts.count > 2 ? Int(parts[2]) : nil
            switch st {
            case 0: return .progress(.remove, percent: nil)
            case 1: return .progress(.set, percent: pct.map { min(max($0, 0), 100) })
            case 2: return .progress(.error, percent: pct)
            case 3: return .progress(.indeterminate, percent: nil)
            case 4: return .progress(.pause, percent: pct)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// OSC 7's body: a URL whose host is where the shell is and whose
    /// path is its directory — `file://` with percent-encoding, or
    /// kitty's scheme with the path as it is.
    static func parseDirectory(_ body: ArraySlice<UInt8>) -> StatusSignal? {
        guard body.count <= 4096, let text = String(bytes: body, encoding: .utf8) else { return nil }
        let (scheme, rest): (String, Substring)
        if let r = text.range(of: "://") {
            scheme = String(text[..<r.lowerBound]).lowercased()
            rest = text[r.upperBound...]
        } else {
            return nil
        }
        guard scheme == "file" || scheme == "kitty-shell-cwd" else { return nil }
        let host = String(rest.prefix { $0 != "/" })
        var path = String(rest.dropFirst(host.count))
        if scheme == "file" { path = path.removingPercentEncoding ?? path }
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return .directory(host: host, path: path)
    }

    /// A 7501 report's body: `key=value(:key=value)*`, as the spec reads
    /// it — malformed pairs skipped, unknown keys ignored, the last of a
    /// repeated key kept, and the whole report dropped for a bad state,
    /// id, or text.
    static func parseReport(_ body: ArraySlice<UInt8>) -> StatusSignal? {
        guard body.count <= 4096 else { return nil }
        let text = String(decoding: body, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespaces) == "?" { return .query }
        var pairs: [String: String] = [:]
        for pair in text.split(separator: ":", omittingEmptySubsequences: false) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<eq].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.count <= 16, key.allSatisfy({ $0.isASCII && $0.isLowercase }),
                  value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.,+/=-".contains($0)) }) else { continue }
            pairs[key] = value
        }
        guard let stateValue = pairs["state"] else { return nil }
        let id = pairs["id"] ?? ""
        if !id.isEmpty {
            let segments = id.split(separator: "/", omittingEmptySubsequences: false)
            guard id.count <= 128, segments.count <= 8, segments.allSatisfy({ !$0.isEmpty && $0.count <= 32 && $0.allSatisfy { $0.isLetter || $0.isNumber || "_.+-".contains($0) } }) else { return nil }
        }
        if stateValue == "clear" { return .clear(id: pairs["id"] == nil ? nil : id) }
        guard let state = StatusState(rawValue: stateValue) else { return nil }
        func decoded(_ key: String, encodedLimit: Int, limit: Int) -> String?? {
            guard let v = pairs[key] else { return .some(nil) }
            guard v.count <= encodedLimit, let data = Data(base64Encoded: v.count % 4 == 0 ? v : v + String(repeating: "=", count: 4 - v.count % 4)),
                  data.count <= limit, let s = String(data: data, encoding: .utf8),
                  !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) })
            else { return nil }
            return .some(s)
        }
        guard let msg = decoded("msg", encodedLimit: 2732, limit: 2048), let title = decoded("title", encodedLimit: 256, limit: 192) else { return nil }
        let kind = state == .blocked ? pairs["kind"].flatMap(BlockedKind.init(rawValue:)) : nil
        let progress = (state == .working || state == .blocked) ? pairs["progress"].flatMap { Int($0) }.flatMap { (0...100).contains($0) ? $0 : nil } : nil
        var app = pairs["app"]
        if let a = app, a.isEmpty || a.count > 32 || !a.allSatisfy({ $0.isLetter || $0.isNumber || "_.+-".contains($0) }) { app = nil }
        return .report(id: id, state: state, kind: kind, progress: progress, app: app, title: title, msg: msg)
    }
}
