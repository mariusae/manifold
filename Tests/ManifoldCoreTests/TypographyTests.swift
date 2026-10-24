import Foundation
import Testing
@testable import ManifoldCore

@Test func featuresAreReadAsTagsAndValues() {
    let s = TypeStyle(family: "X", size: 13, lineHeight: 1.3, features: "ss01, -liga +calt cv05=2, bogus, zero")
    #expect(s.featureTags.map { "\($0.tag)=\($0.value)" } == ["ss01=1", "liga=0", "calt=1", "cv05=2", "zero=1"])
}

@Test func customTypographyIsKeptAndOlderSettingsGetHumanists() throws {
    var a = Appearance()
    a.theme = .custom
    a.typography.reading = TypeStyle(family: "Charter", size: 18, weight: 500, lineHeight: 1.6, tracking: 10, features: "onum", measure: 66, paragraphSpacing: 1.2)
    let back = try JSONDecoder().decode(Appearance.self, from: JSONEncoder().encode(a))
    #expect(back == a)
    // Saved before there was any.
    let old = try JSONDecoder().decode(Appearance.self, from: Data(#"{"theme":"system"}"#.utf8))
    #expect(old.theme == .system && old.typography == .apple && !old.advancedTypography)
    // A style saved with less than there is now.
    let partial = try JSONDecoder().decode(TypeStyle.self, from: Data(#"{"family":"Menlo","size":12}"#.utf8))
    #expect(partial.weight == 400 && partial.lineHeight == 1.3 && partial.paragraphSpacing == 1)
}
