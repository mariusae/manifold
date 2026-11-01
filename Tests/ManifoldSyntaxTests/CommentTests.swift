import Foundation
import Testing
import ManifoldCore
import struct ManifoldCore.TextRange
@testable import ManifoldSyntax

/// The comments' words in each line of a text in the file's language.
private func said(_ path: String, _ text: String) -> [[String]] {
    let rope = Rope(text)
    let tree = SyntaxTree(SyntaxLanguage.forPath(path)!, text: rope, background: false)
    return (0..<rope.lineCount).map { n in tree.commentWords(in: rope.lineRange(n)).map { rope[$0] } }
}

@Test func lineCommentsAreTheirWordsNotTheirLeaders() {
    #expect(said("a.swift", "let a = 1 // one\n/// A doc.\n//   indented\n//\nlet x = 2") == [["one"], ["A doc."], ["indented"], [], []])
    #expect(said("a.rs", "//! Crate.\nfn f() {} // after") == [["Crate."], ["after"]])
    #expect(said("a.py", "x = 1  # one   \n## two") == [["one"], ["two"]])
}

@Test func aLeaderInAStringIsntAComment() {
    #expect(said("a.go", #"var u = "http://x" // y"#) == [["y"]])
    #expect(said("a.py", #"s = "a # b" + 'c # d'  # e"#) == [["e"]])
    #expect(said("a.swift", #"let s = "a \" // b" // c"#) == [["c"]])
    #expect(said("a.css", #"a { background: url("//x"); } /* y */"#) == [["y"]])
    #expect(said("a.c", #"char c = '"'; // q"#) == [["q"]])
}

@Test func blockCommentsSpanLinesAndNestWhereTheLanguageDoes() {
    #expect(said("a.c", "int a /* one */ = 1; /* two\n * three\n */ int c;") == [["one", "two"], ["three"], []])
    #expect(said("a.swift", "/* a /* b */ c */ let d = 1") == [["a /* b */ c"]])
    #expect(said("a.java", "/**\n * Docs.\n */\nclass A {}") == [[], ["Docs."], [], []])
    #expect(said("a.lua", "--[[ long\nstill ]] x = 1 -- short") == [["long"], ["still", "short"]])
    #expect(said("a.html", "<p>don't</p> <!-- note -->") == [["note"]])
    #expect(said("a.c", "/**/ int x;") == [[]])
}

@Test func stringsThatRunOnKeepCommentsOutOfThem() {
    #expect(said("a.py", "s = \"\"\"\n# not\n\"\"\"  # yes") == [[], [], ["yes"]])
    #expect(said("a.swift", "let s = #\"a \" // b\"# // c") == [["c"]])
    #expect(said("a.rs", "let s = r#\"a \" // b\"#; // c\nlet t = \"x\n// y\"; // z") == [["c"], [], ["z"]])
    #expect(said("a.js", "const t = `a\n// b\n${c}` // d") == [[], [], ["d"]])
    #expect(said("a.go", "var s = `a\n// b` // c") == [[], ["c"]])
}

@Test func charactersLifetimesAndShellWords() {
    #expect(said("a.rs", "fn f<'a>(x: &'a str) -> char { '/' } // c") == [["c"]])
    #expect(said("a.sh", "echo $# ${#a} a#b # c") == [["c"]])
    #expect(said("Makefile", "all: # build\n\techo hi") == [["build"], []])
}

@Test func anEditReparsesAndSaysWhatChanged() {
    var rope = Rope("let a = 1\n/* b */\nlet c = 2\n// d */\nlet e = 3")
    let tree = SyntaxTree(SyntaxLanguage.swift, text: rope, background: false)
    #expect(tree.commentWords(in: rope.lineRange(2)).isEmpty)
    // A block opened on the first line takes in everything to its close.
    rope.replace(TextRange(at: 0), with: "/* ")
    let changed = tree.update(to: rope)
    #expect(changed.contains { $0.start <= rope.offset(ofLine: 2) && $0.end >= rope.lineRange(2).end })
    #expect(tree.commentWords(in: rope.lineRange(2)).map { rope[$0] } == ["let c = 2"])
    // And back.
    rope.replace(TextRange(0, 3), with: "")
    tree.update(to: rope)
    #expect(tree.commentWords(in: rope.lineRange(2)).isEmpty)
    #expect(tree.commentWords(in: rope.lineRange(1)).map { rope[$0] } == ["b"])
}

@Test func everyLanguagesCommentsQueryCompiles() {
    for l in SyntaxLanguage.all { #expect(l.commentQuery != nil, "\(l.name)") }
    #expect(SyntaxLanguage.forPath("a.md") == nil)
    #expect(SyntaxLanguage.forPath("/x/.zshrc") === SyntaxLanguage.bash)
}

@Test func whatChangedBetweenTwoTexts() {
    let a = Rope(String(repeating: "abcdefgh\n", count: 2000))
    var b = a
    b.replace(TextRange(9000, 9003), with: "XY")
    let c = b.changed(from: a)!
    #expect(c.start == 9000 && c.oldEnd == 9003 && c.newEnd == 9002)
    #expect(a.changed(from: a) == nil)
    let d = Rope("aaa").changed(from: Rope("aaaa"))!
    #expect(d.start == 3 && d.oldEnd == 4 && d.newEnd == 3)
}

@Test func moreLanguages() {
    #expect(said("a.kt", "val a = 1 // k\n/* b */") == [["k"], ["b"]])
    #expect(said("a.ts", "let a: string = '//' // t") == [["t"]])
    #expect(said("a.rb", "x = 1 # r\n=begin\nblock\n=end\ny = 2") == [["r"], [], ["block"], [], []])
    #expect(said("a.sql", "SELECT 1; -- s\n/* m */ SELECT 2;") == [["s"], ["m"]])
    #expect(said("a.toml", "a = \"#\" # t") == [["t"]])
    #expect(said("a.yaml", "a: 'x # y' # z") == [["z"]])
    #expect(said("a.zig", "/// doc\nconst a = 1; // z") == [["doc"], ["z"]])
    #expect(said("a.ex", "x = \"#{1}\" # e") == [["e"]])
    #expect(said("a.lua", "local s = '--' -- l") == [["l"]])
}

/// In the background: a big text parsed, edited while it is, the tree
/// that comes in brought to the edit and parsed again — told where the
/// syntax changed each time it's in.
@Test @MainActor func aBigTextParsesInTheBackgroundAndKeepsUpWithEdits() async {
    let line = "    let value = compute(x, y) // what it is\n"
    var rope = Rope("func f() {\n" + String(repeating: line, count: 50_000) + "}\n")
    let tree = SyntaxTree(SyntaxLanguage.swift, text: rope)
    #expect(!tree.isParsed)
    // A block comment put round lines halfway, an edit at a time, before
    // the first parse is in.
    rope.replace(TextRange(at: rope.offset(ofLine: 25_000)), with: "/*\n")
    tree.update(to: rope)
    rope.replace(TextRange(at: rope.offset(ofLine: 35_000)), with: "*/\n")
    tree.update(to: rope)
    var told: [[TextRange]] = []
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        tree.onChange = { ranges in
            told.append(ranges)
            if told.count == 2 { done.resume() }
        }
    }
    #expect(told[0] == [TextRange(0, rope.count)])
    #expect(tree.commentWords(in: rope.lineRange(30_000)).map { rope[$0] } == ["let value = compute(x, y) // what it is"])
    #expect(tree.commentWords(in: rope.lineRange(20_000)).map { rope[$0] } == ["what it is"])
}

/// The doc comments' words in each line.
private func documented(_ path: String, _ text: String) -> [[String]] {
    let rope = Rope(text)
    let tree = SyntaxTree(SyntaxLanguage.forPath(path)!, text: rope, background: false)
    return (0..<rope.lineCount).map { n in tree.docWords(in: rope.lineRange(n)).map { rope[$0] } }
}

@Test func docCommentsAreTheOnesWrittenSo() {
    #expect(documented("a.swift", "/// Doc.\n// Not.\n//// Not either.\n/** Block doc. */\n/* Not. */\n/**/ let a = 1") == [["Doc."], [], [], ["Block doc."], [], []])
    #expect(documented("a.rs", "/// Outer.\n//! Inner.\n// Plain.\n//// Plain too.\n/** Block. */ fn f() {}") == [["Outer."], ["Inner."], [], [], ["Block."]])
    #expect(documented("a.c", "/// D.\n//! E.\n/** F. */\n/*! G. */\n// H.\nint x;") == [["D."], ["E."], ["F."], ["G."], [], []])
    #expect(documented("a.java", "/**\n * Docs.\n */\n/* Not. */\n// Not.\nclass A {}") == [[], ["Docs."], [], [], [], []])
    #expect(documented("a.ts", "/** T. */\n// U.\nlet a = 1") == [["T."], [], []])
    #expect(documented("a.zig", "/// Z.\n// Y.\nconst a = 1;") == [["Z."], [], []])
    #expect(documented("a.lua", "--- L.\n-- M.\nlocal a = 1") == [["L."], [], []])
}

@Test func docCommentsAreTheRunJustAboveADeclaration() {
    let go = "// Copyright.\n\n// Package p does.\npackage p\n\n// F does x\n// and y.\nfunc F() {\n\t// inside\n\tx := 1\n}\n// trailing\n"
    #expect(documented("a.go", go) == [[], [], ["Package p does."], [], [], ["F does x"], ["and y."], [], [], [], [], [], []])
    let ruby = "# frozen\n\n# A thing.\nclass A\n  # Does it.\n  def f\n    # inside\n  end\nend"
    #expect(documented("a.rb", ruby) == [[], [], ["A thing."], [], ["Does it."], [], [], [], []])
}

@Test func docstringsAndDocAttributes() {
    let py = "\"\"\"Module.\"\"\"\n# not\ndef f():\n    \"\"\"Doc of f,\n    two lines.\"\"\"\n    s = \"not\"\n"
    #expect(documented("a.py", py) == [["Module."], [], [], ["Doc of f,"], ["two lines."], [], []])
    let ex = "defmodule A do\n  @moduledoc \"\"\"\n  Module.\n  \"\"\"\n  @doc \"F.\"\n  @foo \"not\"\n  # not\n  def f, do: 1\nend"
    #expect(documented("a.ex", ex) == [[], [], ["Module."], [], ["F."], [], [], [], []])
}

@Test func everyLanguagesDocQueryCompiles() {
    for l in SyntaxLanguage.all where l.docSource != nil { #expect(l.docQuery != nil, "\(l.name)") }
}
