import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: History



    /// History of This File (⌥⌘Y) where no editor took it (an editor
    /// shows its file's version control history itself, `EditorHistory`):
    /// the text's history in Manifold, over the window.
    @objc func showFileHistory(_ sender: Any?) {
        guard history == nil else { return hideHistory() }
        guard let f = focusedShown, f.kind == .text else { return }
        showManifoldHistory(f.placement.block, placement: f.id)
    }

    func editor(_ view: EditorView, fileHistory request: FileHistoryRequest, done: @escaping (FileHistoryResult) -> Void) {
        guard let c = hosts.client(of: view.block) else { return done(.error("the host isn't attached")) }
        c.fileHistory(request, done: done)
    }

    /// An editor's file in no repository: its history in Manifold.
    func editorShowsManifoldHistory(_ view: EditorView) {
        guard history == nil else { return }
        showManifoldHistory(view.block, placement: view.placement)
    }

    private func showManifoldHistory(_ block: BlockID, placement: PlacementID) {
        let h = makeHistory()
        h.font = hosts.state.appearance.theme.font(hosts.state.appearance.editorFont, size: hosts.state.appearance.theme.editorSize(hosts.state.appearance.editorFont))
        h.onRestoreText = { [weak self] text in self?.restore(block, toText: text) }
        h.onCompare = { [weak self] moment in
            guard let self, let client = self.hosts.client(of: block) else { return }
            self.hideHistory()
            let diff = client.diffBlock(.versions(block: block, from: moment, to: nil))
            self.show(diff, lens: .diff, .besideOpener(placement), context: "Compare with Now")
        }
        h.onOpen = { [weak self] text, moment in
            guard let self, let client = self.hosts.client(of: block) else { return }
            self.hideHistory()
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            let title = "\(self.hosts.block(block)?.displayTitle ?? "Text") as of \(f.string(from: moment.date))"
            let id = BlockID(host: block.host)
            client.append([.create(kind: .output, title: title, path: nil),
                           .output(OutputState(line: title, ended: moment, output: text, plain: true))], to: .block(id))
            self.show(id, lens: .output, .besideOpener(placement), context: "as of \(f.string(from: moment.date))")
        }
        historyOf = block
        hosts.propose(.history(.block(block)))
    }

    private func makeHistory() -> HistoryView {
        let h = HistoryView(frame: root.bounds)
        h.onClose = { [weak self] in self?.hideHistory() }
        h.titleOf = { [weak self] block in self?.hosts.block(block)?.displayTitle ?? "?" }
        h.symbolOf = { lens in Theme.symbolName(for: lens) }
        root.addSubview(h, positioned: .above, relativeTo: nil)
        history = h
        return h
    }

    func debugHideVersions() { hideHistory() }

    private func hideHistory() {
        history?.removeFromSuperview()
        history = nil
        historyOf = nil
    }

    func historyArrived(_ shard: ShardID, _ base: Block?, _ entries: [Entry]) {
        // The inspector's ask: its log's latest, kept.
        if let block = shard.block, inspectorAsked.contains(block) {
            inspectorLogs[block] = Array(entries.suffix(500))
            refreshInspector()
        }
        guard let history, let block = shard.block, block == historyOf else { return }
        history.showText(entries: entries, block: block, base: base)
    }

    /// A text block's text made what it was: one edit, in the log like
    /// any other (so it undoes, and is itself in the history).
    private func restore(_ block: BlockID, toText text: String) {
        guard let t = hosts.block(block)?.text, t.text.string != text else { return hideHistory() }
        hosts.append(.edit([TextEdit(TextRange(0, t.text.count), text)]), to: .block(block))
        hideHistory()
    }
}
