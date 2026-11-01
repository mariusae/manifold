import Foundation
import Testing
@testable import ManifoldCore

/// The comments' words in each line, scanned in order from the start.
private func said(_ path: String, _ text: String) -> [[String]] {
    let syntax = CommentSyntax.forPath(path)!
    var state = CommentState.code
    return text.components(separatedBy: "\n").map { line in
        let bytes = Array(line.utf8)
        let (ranges, end) = syntax.scan(bytes, from: state)
        state = end
        return ranges.map { String(decoding: bytes[$0], as: UTF8.self) }
    }
}

@Test func lineCommentsAreTheirWordsNotTheirLeaders() {
    #expect(said("a.swift", "let a = 1 // one\n/// A doc.\n//   indented\n//\nx") == [["one"], ["A doc."], ["indented"], [], []])
    #expect(said("a.rs", "//! Crate.\nfn f() {} // after") == [["Crate."], ["after"]])
    #expect(said("a.py", "x = 1  # one   \n## two") == [["one"], ["two"]])
}

@Test func aLeaderInAStringIsntAComment() {
    #expect(said("a.go", #"u := "http://x" // y"#) == [["y"]])
    #expect(said("a.py", #"s = "a # b" + 'c # d'  # e"#) == [["e"]])
    #expect(said("a.swift", #"let s = "a \" // b" // c"#) == [["c"]])
    #expect(said("a.css", #"a { background: url("//x"); } /* y */"#) == [["y"]])
    #expect(said("a.c", #"char c = '"'; // q"#) == [["q"]])
}

@Test func blockCommentsCarryOnAndNestWhereTheLanguageDoes() {
    #expect(said("a.c", "a /* one */ b /* two\n * three\n */ c") == [["one", "two"], ["three"], []])
    #expect(said("a.swift", "/* a /* b */ c */ d") == [["a /* b */ c"]])
    #expect(said("a.c", "/* a /* b */ c */ d") == [["a /* b"]])
    #expect(said("a.java", "/**\n * Docs.\n */") == [[], ["Docs."], []])
    #expect(said("a.hs", "{- a {- b -} c -}\nx -- y") == [["a {- b -} c"], ["y"]])
    #expect(said("a.lua", "--[[ long\nstill ]] x -- short") == [["long"], ["still", "short"]])
    #expect(said("a.html", "<p>don't</p> <!-- note -->") == [["note"]])
}

@Test func stringsThatRunOnKeepCommentsOutOfThem() {
    #expect(said("a.py", "s = \"\"\"\n# not\n\"\"\"  # yes") == [[], [], ["yes"]])
    #expect(said("a.swift", "let s = #\"a \" // b\"# // c") == [["c"]])
    #expect(said("a.rs", "let s = r#\"a \" // b\"#; // c\nlet t = \"x\n// y\"; // z") == [["c"], [], ["z"]])
    #expect(said("a.js", "const t = `a\n// b\n${c}` // d") == [[], [], ["d"]])
    #expect(said("a.go", "s := `a\n// b` // c") == [[], ["c"]])
}

@Test func charactersAndLifetimesAreToldApart() {
    #expect(said("a.rs", "fn f<'a>(x: &'a str) -> char { '/' } // c") == [["c"]])
    #expect(said("a.rs", "let q = '\\''; // c") == [["c"]])
    #expect(said("a.dart", "var s = 'http://x'; // c") == [["c"]])
}

@Test func leadersOnlyWhereTheLanguageTakesThem() {
    #expect(said("a.sh", "echo $# ${#a} a#b # c") == [["c"]])
    #expect(said("a.ini", "a = b ; not\n; yes") == [[], ["yes"]])
    #expect(said("a.tex", "50\\% off % c") == [["c"]])
    #expect(said("Makefile", "all: # build") == [["build"]])
}

@Test func unknownAndProseHaveNone() {
    #expect(CommentSyntax.forPath("a.md") == nil)
    #expect(CommentSyntax.forPath("a.weird") == nil)
    #expect(CommentSyntax.forPath("/x/.zshrc") != nil)
}
