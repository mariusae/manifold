import Foundation
import Testing
@testable import ManifoldCore

@Test func theCarriedTerminfoIsGhosttysInTheFormatEveryNcursesReads() throws {
    let entry = GhosttyTerminfo.entry
    // ncurses' original format (magic 0432, little-endian), not 6.1's
    // extended numbers (01036), which older ncurses can't read.
    #expect(entry.prefix(2) == Data([0x1a, 0x01]))
    let namesSize = Int(entry[2]) | Int(entry[3]) << 8
    let names = String(decoding: entry[12..<(12 + namesSize - 1)], as: UTF8.self)
    #expect(names.split(separator: "|").prefix(2).map(String.init) == GhosttyTerminfo.names)
}

@Test func theTerminfoIsWrittenWhereEitherNcursesLooksAndLeftIfTheSame() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminfo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(GhosttyTerminfo.install(in: dir))
    for path in ["x/xterm-ghostty", "78/xterm-ghostty", "g/ghostty", "67/ghostty"] {
        #expect(try Data(contentsOf: dir.appendingPathComponent(path)) == GhosttyTerminfo.entry)
    }
    // Written again over another's, and not again once it's the same.
    let file = dir.appendingPathComponent("x/xterm-ghostty")
    try Data("stale".utf8).write(to: file)
    #expect(GhosttyTerminfo.install(in: dir))
    #expect(try Data(contentsOf: file) == GhosttyTerminfo.entry)
    let written = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    Thread.sleep(forTimeInterval: 0.01)
    #expect(GhosttyTerminfo.install(in: dir))
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == written)
}

@Test func theHostsNcursesFindsTheTerminalInTheWrittenFolder() throws {
    let infocmp = ["/usr/bin/infocmp", "/bin/infocmp"].first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let infocmp else { return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminfo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(GhosttyTerminfo.install(in: dir))
    for name in GhosttyTerminfo.names {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: infocmp)
        p.arguments = ["-x", name]
        // Only the written folder: not this Mac's app bundle, if the
        // tests run in a Manifold terminal.
        p.environment = ["TERMINFO": dir.path, "HOME": dir.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        // Ghostty's own capabilities, as well as xterm's: what ⌫ sends,
        // the cursor moved back for it, true color, synchronized output.
        for cap in ["kbs=\\177", "cub1=^H", "Tc", "Sync="] { #expect(text.contains(cap), "\(name) has no \(cap)") }
    }
}
