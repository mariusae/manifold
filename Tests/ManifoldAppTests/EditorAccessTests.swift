import Testing
@testable import Manifold

// I-4, M15 (STATE-MACHINES.md): one rule for whether the text can be typed
// in, from every reason at once.

@Test func aPastRevisionStaysReadOnlyWhateverElseChanges() {
    // Its host back (offline false), loaded, readable, not viewing: still a
    // past revision, so still read-only.
    #expect(EditorView.readOnly(loaded: true, unreadable: false, offline: false, past: true, viewing: false) == [.past])
    #expect(EditorView.readOnly(loaded: true, unreadable: false, offline: true, past: true, viewing: false) == [.offline, .past])
}

@Test func theTextIsEditableOnlyWithNothingAgainstIt() {
    #expect(EditorView.readOnly(loaded: true, unreadable: false, offline: false, past: false, viewing: false).isEmpty)
    #expect(EditorView.readOnly(loaded: false, unreadable: false, offline: false, past: false, viewing: false) == [.reading])
    #expect(EditorView.readOnly(loaded: true, unreadable: true, offline: false, past: false, viewing: true) == [.unreadable, .viewing])
}
