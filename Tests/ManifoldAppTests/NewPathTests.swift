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
