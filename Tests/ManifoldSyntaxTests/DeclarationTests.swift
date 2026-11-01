import Foundation
import Testing
import ManifoldCore
import struct ManifoldCore.TextRange
@testable import ManifoldSyntax

/// The declarations' paths in a text of the file's language.
private func paths(_ path: String, _ text: String) -> [String] {
    SyntaxTree(SyntaxLanguage.forPath(path)!, text: Rope(text), background: false).declarations().map(\.path)
}

@Test func everyLanguagesDeclarationQueryCompiles() {
    for l in SyntaxLanguage.all where l.declarationSource != nil { #expect(l.declarationQuery != nil, "\(l.name)") }
}

@Test func declarationsArePathsOfWhatTheyreIn() {
    #expect(paths("a.swift", """
        struct Card {
            init() {}
            func save() {}
            struct Field { func check() {} }
        }
        extension Card { func load() {} }
        protocol Store { func put() }
        func top() {}
        """) == ["Card", "Card.init", "Card.save", "Card.Field", "Card.Field.check", "Card", "Card.load", "Store", "Store.put", "top"])
    #expect(paths("a.rs", "struct S;\nimpl S { fn new() -> S { S } }\nmod m { fn f() {} }\ntrait T { fn g(&self); }") == ["S", "S", "S.new", "m", "m.f", "T", "T.g"])
    #expect(paths("a.go", "package p\ntype T struct{}\nfunc (t *T) Run() {}\nfunc Main() {}") == ["T", "T.Run", "Main"])
    #expect(paths("a.py", "class A:\n    def f(self):\n        def inner(): pass\ndef g(): pass") == ["A", "A.f", "A.f.inner", "g"])
    #expect(paths("a.ts", "class A { m() {} }\ninterface I {}\nconst f = () => 1\nfunction g() {}") == ["A", "A.m", "I", "f", "g"])
    #expect(paths("a.c", "struct s { int x; };\nint main(void) { return 0; }\nstatic char *name(void) { return 0; }") == ["s", "main", "name"])
    #expect(paths("a.rb", "module M\n  class C\n    def run; end\n  end\nend") == ["M", "M.C", "M.C.run"])
    #expect(paths("a.java", "class A { A() {} void f() {} }") == ["A", "A.A", "A.f"])
    #expect(paths("a.kt", "class A { fun f() {} }\nfun g() {}") == ["A", "A.f", "g"])
    #expect(paths("a.ex", "defmodule M do\n  def f(x), do: x\n  defp g, do: 1\nend") == ["M", "M.f", "M.g"])
}
