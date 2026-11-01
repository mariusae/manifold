import Foundation
import Testing
@testable import ManifoldCore

/// rust-analyzer's index of a small crate: main.rs (a Card, main calling
/// store::save twice) and store.rs (save).
private let crate = Data(base64Encoded: "CqIBEi0KDXJ1c3QtYW5hbHl6ZXISHDEuOTguMSAoNDhhMjI5Y2UgMjAyNi0wOS0wMSkab2ZpbGU6Ly8vcHJpdmF0ZS90bXAvY2xhdWRlLTUwMS8tVXNlcnMtbWFyaXVzLXNyYy1tYW5pZm9sZC8xYjE5NDhiMC03MzExLTRjZGItYjMyZS0yOWVmY2EwZmI4MDAvc2NyYXRjaHBhZC9jcmF0ZSABEowKIgRydXN0CgtzcmMvbWFpbi5ycxI2CgQAAAwAEiZydXN0LWFuYWx5emVyIGNhcmdvIGNhcmRzIDAuMS4wIGNyYXRlLxgBOgQAAAwAEi0KAwAECRImcnVzdC1hbmFseXplciBjYXJnbyBjYXJkcyAwLjEuMCBzdG9yZS8SNAoDAwsPEiVydXN0LWFuYWx5emVyIGNhcmdvIGNhcmRzIDAuMS4wIENhcmQjGAE6BAIABQESOQoDBAgNEitydXN0LWFuYWx5emVyIGNhcmdvIGNhcmRzIDAuMS4wIENhcmQjdGl0bGUuGAE6AwQEFRJfCgMEDxUSWHJ1c3QtYW5hbHl6ZXIgY2FyZ28gYWxsb2MgaHR0cHM6Ly9naXRodWIuY29tL3J1c3QtbGFuZy9ydXN0L2xpYnJhcnkvYWxsb2Mgc3RyaW5nL1N0cmluZyMSNgoDBwMHEidydXN0LWFuYWx5emVyIGNhcmdvIGNhcmRzIDAuMS4wIG1haW4oKS4YAToEBwALARIVCgMICAwSB2xvY2FsIDAYAToDCAgMEjIKAwgPExIlcnVzdC1hbmFseXplciBjYXJnbyBjYXJkcyAwLjEuMCBDYXJkIzoEAgAFARI3CgMIFhsSK3J1c3QtYW5hbHl6ZXIgY2FyZ28gY2FyZHMgMC4xLjAgQ2FyZCN0aXRsZS46AwQEFRJxCgMIIycSanJ1c3QtYW5hbHl6ZXIgY2FyZ28gY29yZSBodHRwczovL2dpdGh1Yi5jb20vcnVzdC1sYW5nL3J1c3QvbGlicmFyeS9jb3JlIGNvbnZlcnQvaW1wbCNbVF1bYEludG88VT5gXWludG8oKS4SLQoDCQQJEiZydXN0LWFuYWx5emVyIGNhcmdvIGNhcmRzIDAuMS4wIHN0b3JlLxI0CgMJCw8SLXJ1c3QtYW5hbHl6ZXIgY2FyZ28gY2FyZHMgMC4xLjAgc3RvcmUvc2F2ZSgpLhITCgMJERUSB2xvY2FsIDA6AwgIDBItCgMKBAkSJnJ1c3QtYW5hbHl6ZXIgY2FyZ28gY2FyZHMgMC4xLjAgc3RvcmUvEjQKAwoLDxItcnVzdC1hbmFseXplciBjYXJnbyBjYXJkcyAwLjEuMCBzdG9yZS9zYXZlKCkuEhMKAwoRFRIHbG9jYWwgMDoDCAgMGkgKJnJ1c3QtYW5hbHl6ZXIgY2FyZ28gY2FyZHMgMC4xLjAgY3JhdGUvKB06HCIEcnVzdCoSZXh0ZXJuIGNyYXRlIGNhcmRzMAEaXAolcnVzdC1hbmFseXplciBjYXJnbyBjYXJkcyAwLjEuMCBDYXJkIxoQQSBjYXJkLCBhcyBrZXB0LigxMgRDYXJkOhkiBHJ1c3QqD3B1YiBzdHJ1Y3QgQ2FyZDABGlMKK3J1c3QtYW5hbHl6ZXIgY2FyZ28gY2FyZHMgMC4xLjAgQ2FyZCN0aXRsZS4oDzIFdGl0bGU6GyIEcnVzdCoRcHViIHRpdGxlOiBTdHJpbmcwARpGCidydXN0LWFuYWx5emVyIGNhcmdvIGNhcmRzIDAuMS4wIG1haW4oKS4oETIEbWFpbjoTIgRydXN0KglmbiBtYWluKCkwARpUCgdsb2NhbCAwKD0yBGNhcmQ6GCIEcnVzdCoObGV0IGNhcmQ6IENhcmQwAUIncnVzdC1hbmFseXplciBjYXJnbyBjYXJkcyAwLjEuMCBtYWluKCkuMAES5QUiBHJ1c3QKDHNyYy9zdG9yZS5ycxI2CgQAAAYAEiZydXN0LWFuYWx5emVyIGNhcmdvIGNhcmRzIDAuMS4wIHN0b3JlLxgBOgQAAAYAEi0KAwAECRImcnVzdC1hbmFseXplciBjYXJnbyBjYXJkcyAwLjEuMCBjcmF0ZS8SLAoDAAsPEiVydXN0LWFuYWx5emVyIGNhcmdvIGNhcmRzIDAuMS4wIENhcmQjEjwKAwMHCxItcnVzdC1hbmFseXplciBjYXJnbyBjYXJkcyAwLjEuMCBzdG9yZS9zYXZlKCkuGAE6BAIABQESFQoDAwwQEgdsb2NhbCAwGAE6AwMMEBIsCgMDExcSJXJ1c3QtYW5hbHl6ZXIgY2FyZ28gY2FyZHMgMC4xLjAgQ2FyZCMSXAoDBAQLElVydXN0LWFuYWx5emVyIGNhcmdvIHN0ZCBodHRwczovL2dpdGh1Yi5jb20vcnVzdC1sYW5nL3J1c3QvbGlicmFyeS9zdGQgbWFjcm9zL3ByaW50bG4hEhMKAwQTFxIHbG9jYWwgMDoDAwwQEjIKAwQYHRIrcnVzdC1hbmFseXplciBjYXJnbyBjYXJkcyAwLjEuMCBDYXJkI3RpdGxlLhpGCiZydXN0LWFuYWx5emVyIGNhcmdvIGNhcmRzIDAuMS4wIHN0b3JlLygdMgVzdG9yZToTIgRydXN0Kgltb2Qgc3RvcmUwARptCi1ydXN0LWFuYWx5emVyIGNhcmdvIGNhcmRzIDAuMS4wIHN0b3JlL3NhdmUoKS4aEFdyaXRlcyB0aGUgY2FyZC4oETIEc2F2ZToiIgRydXN0KhhwdWIgZm4gc2F2ZShjYXJkOiAmQ2FyZCkwARpXCgdsb2NhbCAwKCUyBGNhcmQ6FSIEcnVzdCoLY2FyZDogJkNhcmQwAUItcnVzdC1hbmFseXplciBjYXJnbyBjYXJkcyAwLjEuMCBzdG9yZS9zYXZlKCkuMAE=")!

@Test func anIndexSaysWhereASymbolIsDefinedAndUsed() throws {
    let index = try SCIPIndex.read(crate)
    #expect(Set(index.documents.keys) == ["src/main.rs", "src/store.rs"])
    // "pub fn save(card: &Card) {": its name, on line 3 (from 0).
    let save = try #require(index.symbol(at: "src/store.rs", line: 3, character: 8))
    #expect(index.name(of: save).hasSuffix("save"))
    #expect(index.definitions(of: save).map(\.path) == ["src/store.rs"])
    let refs = index.references(to: save)
    #expect(refs.map(\.path) == ["src/main.rs", "src/main.rs", "src/store.rs"])
    #expect(refs.filter { $0.occurrence.isDefinition }.count == 1)
    // What store.rs defines: save, among them.
    #expect(index.defined(in: "src/store.rs").contains { $0.symbol == save })
    // The Card is used from both files.
    let card = try #require(index.symbol(at: "src/main.rs", line: 3, character: 12))
    #expect(Set(index.references(to: card).map(\.path)) == ["src/main.rs", "src/store.rs"])
}

@Test func aSymbolsNameIsItsLastDescriptors() {
    #expect(SCIPIndex.descriptorName("rust-analyzer cargo cards 0.1.0 store/save().") == "store.save")
    #expect(SCIPIndex.descriptorName("scip-typescript npm app 1.0 src/`card.ts`/Card#save().") == "Card.save")
}

@Test func anIndexerIsFoundByItsProjectsMarkers() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
    try Data().write(to: dir.appendingPathComponent("Cargo.toml"))
    let (indexer, root) = try #require(SCIPIndexer.forFile(dir.appendingPathComponent("src/main.rs").path))
    #expect(indexer.id == "rust" && root == dir.path)
    #expect(indexer.command(root: root, out: "/tmp/x y.scip").hasSuffix("--output '/tmp/x y.scip'"))
    #expect(SCIPIndexer.forFile(dir.appendingPathComponent("src/main.py").path) == nil)
    try? FileManager.default.removeItem(at: dir)
}
