import Foundation
import Testing
@testable import Manifold

// A file Quick Look doesn't know is shown as text when it is text.
@Test func unknownFilesThatAreTextShowAsText() {
    #expect(!FilePreviewView.quickLookKnows(URL(fileURLWithPath: "/x/resource.thrift")))
    #expect(FilePreviewView.quickLookKnows(URL(fileURLWithPath: "/x/a.png")))
    #expect(FilePreviewView.looksLikeText(Data("struct Resource { 1: string id }\n".utf8)))
    #expect(!FilePreviewView.looksLikeText(Data([0x7f, 0x45, 0x4c, 0x46, 0x00, 0x01])))
    // Cut mid-character at its end: still text.
    let e = Data("café".utf8)
    #expect(FilePreviewView.looksLikeText(e.dropLast(1)))
}
