import Foundation
import Testing
@testable import Manifold

// A name typed for a new file or folder in a listing, as the path it makes.
@Suite struct NewPathTests {
    @Test func plainName() {
        let p = DirectoryView.newPath("notes.md", folder: false, in: "/r")
        #expect(p?.path == "/r/notes.md")
        #expect(p?.isDirectory == false)
    }

    @Test func foldersOnTheWay() {
        let p = DirectoryView.newPath(" src/ui/View.swift ", folder: false, in: "/r")
        #expect(p?.path == "/r/src/ui/View.swift")
        #expect(p?.isDirectory == false)
    }

    @Test func trailingSlashIsAFolder() {
        let p = DirectoryView.newPath("build/out/", folder: false, in: "/r")
        #expect(p?.path == "/r/build/out")
        #expect(p?.isDirectory == true)
        #expect(DirectoryView.newPath("x", folder: true, in: "/r")?.isDirectory == true)
    }

    @Test func noName() {
        #expect(DirectoryView.newPath("", folder: false, in: "/r") == nil)
        #expect(DirectoryView.newPath("  / ", folder: false, in: "/r") == nil)
        #expect(DirectoryView.newPath("../x", folder: false, in: "/r") == nil)
        #expect(DirectoryView.newPath("a/./b", folder: true, in: "/r") == nil)
    }
}

// A name typed for an entry renamed; the part of it chosen to type over.
@Suite struct RenameTests {
    @Test func renamedBeside() {
        #expect(DirectoryView.renamed("/r/a/old.txt", to: " new.md ") == "/r/a/new.md")
        #expect(DirectoryView.renamed("/r/a/old.txt", to: "old.txt") == "/r/a/old.txt")
    }

    @Test func notAName() {
        #expect(DirectoryView.renamed("/r/a", to: "") == nil)
        #expect(DirectoryView.renamed("/r/a", to: "b/c") == nil)
        #expect(DirectoryView.renamed("/r/a", to: "..") == nil)
    }

    @Test func stem() {
        #expect(DirectoryView.stem("View.swift") == "View")
        #expect(DirectoryView.stem("archive.tar.gz") == "archive.tar")
        #expect(DirectoryView.stem(".gitignore") == ".gitignore")
        #expect(DirectoryView.stem("Makefile") == "Makefile")
    }
}
