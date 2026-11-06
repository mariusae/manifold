import AppKit
import ManifoldCore

/// Where an editor is in its file's history: the repository's, the commits
/// that changed the file (newest first), and the one shown (nil: now).
/// What the host gave, kept: each commit's text, and its blame.
struct FileHistoryState {
    var root: String
    var vcs: VCS
    var revisions: [FileRevision]
    var more: Bool
    var position: Int?
    var texts: [String: String] = [:]
    var blames: [String: BlameLines] = [:]
    /// The last commit's text and blame, for blame now (carried onto the
    /// text as it is).
    var head: (text: String, blame: BlameLines)?
    /// The history's strip is shown (blame alone asks for the repository too).
    var shown = false
}

/// A file's history in its editor (⌥⌘Y): a strip along its foot, its
/// commits as ticks; one chosen, the text as that commit left it, read-only
/// in place, on a page tinted so it isn't taken for the file as it is, and
/// what that commit changed marked in the gutter. The view stays on the
/// same lines as it goes back and forth. And blame (⌃⌘B): each line's
/// commit in a column — as of the commit shown, or of the text as it is.
/// For a file in no repository, Manifold's own history (the overlay).
extension EditorView {
    static let historyPage = 200

    // MARK: History

    @objc func showFileHistory(_ sender: Any?) {
        if fileHistory?.shown == true { return closeFileHistory() }
        guard !path.isEmpty else { return delegate?.editorShowsManifoldHistory(self) ?? () }
        loadHistory { [weak self] ok in
            guard let self, ok else { return }
            self.fileHistory?.shown = true
            self.showStrip()
        }
    }

    /// The repository and the first page of commits, asked for once.
    func loadHistory(_ done: @escaping (Bool) -> Void) {
        if fileHistory != nil { return done(true) }
        delegate?.editor(self, fileHistory: .log(path: path, skip: 0, limit: Self.historyPage)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .untracked:
                self.delegate?.editorShowsManifoldHistory(self)
                done(false)
            case let .log(root, vcs, revisions, more):
                self.fileHistory = FileHistoryState(root: root, vcs: vcs, revisions: revisions, more: more)
                done(true)
            case .error(let m):
                self.flash("History: " + m)
                done(false)
            default:
                done(false)
            }
        }
    }

    private func showStrip() {
        guard let h = fileHistory else { return }
        historyStrip.revisions = h.revisions
        historyStrip.more = h.more
        historyStrip.position = h.position
        historyStrip.onChoose = { [weak self] i in self?.goToRevision(i) }
        historyStrip.onClose = { [weak self] in self?.closeFileHistory() }
        historyStrip.onMore = { [weak self] in self?.loadOlder() }
        if historyStrip.superview !== self { addSubview(historyStrip) }
        needsLayout = true
    }

    func closeFileHistory() {
        goToRevision(nil)
        fileHistory?.shown = false
        historyStrip.removeFromSuperview()
        needsLayout = true
        // Read again when next asked for (commits made meanwhile), unless
        // blame still uses what's known.
        if !blameShown { fileHistory = nil }
    }

    /// Older commits, the next page.
    func loadOlder() {
        guard let h = fileHistory, h.more else { return }
        delegate?.editor(self, fileHistory: .log(path: path, skip: h.revisions.count, limit: Self.historyPage)) { [weak self] result in
            guard let self, case let .log(_, _, older, more) = result else { return }
            self.fileHistory?.revisions += older
            self.fileHistory?.more = more
            self.historyStrip.revisions = self.fileHistory?.revisions ?? []
            self.historyStrip.more = more
        }
    }

    /// A commit further back, or nearer now ([ and ] while back in time).
    @objc func olderRevision(_ sender: Any?) { historyStrip.step(older: true) }
    @objc func newerRevision(_ sender: Any?) { historyStrip.step(older: false) }

    /// The text as commit `i` left it (nil: as it is now), shown in place;
    /// the view kept on the same lines.
    func goToRevision(_ i: Int?) {
        guard var h = fileHistory, i.map({ h.revisions.indices.contains($0) }) ?? true else { return }
        historyAsked += 1
        let asked = historyAsked
        guard let i else {
            guard h.position != nil else { return }
            let top = mapLine(topLine, from: textView.text.string, to: rope.string)
            h.position = nil
            fileHistory = h
            historyStrip.position = nil
            historyStrip.loading = false
            textView.document = self
            pastDocument = nil
            textView.documentChanged()
            showPage()
            documentChanged()
            gutterChanged()
            diagnosticsChanged()
            scroll(toTopLine: top)
            refreshBlame()
            return
        }
        let r = h.revisions[i]
        historyStrip.position = i
        historyStrip.loading = h.texts[r.sha] == nil
        revisionText(r) { [weak self] text in
            guard let self, asked == self.historyAsked, let text else { return }
            self.historyStrip.loading = false
            let top = self.mapLine(self.topLine, from: self.textView.text.string, to: text)
            self.fileHistory?.position = i
            let doc = StaticDocument()
            doc.rope = Rope(text)
            // A version of its own, so the view takes it as new.
            doc.version = -asked
            self.pastDocument = doc
            self.textView.document = doc
            self.textView.isEditable = false
            self.textView.documentChanged()
            self.textView.diagnostics = []
            self.textView.gutterMarks = []
            self.showPage()
            self.scroll(toTopLine: top)
            self.markChanges(of: i, text: text, asked: asked)
            self.refreshBlame()
        }
    }

    /// A commit's text, kept once read.
    private func revisionText(_ r: FileRevision, _ done: @escaping (String?) -> Void) {
        if let t = fileHistory?.texts[r.sha] { return done(t) }
        delegate?.editor(self, fileHistory: .text(file: path, path: r.path, revision: r.sha)) { [weak self] result in
            guard case .text(let t) = result else { return done(nil) }
            self?.fileHistory?.texts[r.sha] = t
            done(t)
        }
    }

    /// What commit `i` changed, in the gutter: its text against the commit
    /// before it (the file's first, all of it added).
    private func markChanges(of i: Int, text: String, asked: Int) {
        guard let h = fileHistory else { return }
        func mark(_ before: String) {
            guard asked == historyAsked else { return }
            textView.gutterMarks = LineDiff.hunks(old: before, new: text).map { d in
                if d.newCount == 0 { return GutterMark(line: d.newStart, count: 0, kind: .deleted) }
                return GutterMark(line: d.newStart, count: d.newCount, kind: d.oldCount == 0 ? .added : .modified)
            }
        }
        guard h.revisions.indices.contains(i + 1) else { return h.more ? () : mark("") }
        revisionText(h.revisions[i + 1]) { before in mark(before ?? "") }
    }

    /// A line (from 0, a fraction into it) in one text, where it is in
    /// another: carried through their difference, so what was read stays
    /// in view as the text goes back and forth.
    func mapLine(_ line: Double, from old: String, to new: String) -> Double {
        let n = Int(line), frac = line - Double(n)
        var delta = 0
        for d in LineDiff.hunks(old: old, new: new) {
            if n < d.oldStart { break }
            if n < d.oldStart + d.oldCount {
                // In what changed: its place in the new lines, as near as there is.
                return Double(d.newStart + min(n - d.oldStart, max(d.newCount - 1, 0)))
            }
            delta = d.newStart + d.newCount - (d.oldStart + d.oldCount)
        }
        return max(0, Double(n + delta) + frac)
    }

    /// The page: tinted while back in time — a past version, read-only,
    /// not the file as it is — else as the mode has it.
    func showPage() {
        let base = viewing ? Theme.codePage : Theme.windowBackground
        let page = scrubbed ? (base.blended(withFraction: 0.08, of: Theme.accent) ?? base) : base
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = page.cgColor
        }
        pinned.background = page
    }

    // MARK: Blame

    @objc func toggleBlame(_ sender: Any?) {
        blameShown.toggle()
        guard blameShown else {
            textView.blame = nil
            if fileHistory?.shown != true { fileHistory = nil }
            return
        }
        guard !path.isEmpty else { blameShown = false; return delegate?.editorShowsManifoldHistory(self) ?? () }
        loadHistory { [weak self] ok in
            guard let self else { return }
            guard ok else { self.blameShown = false; return }
            self.refreshBlame()
        }
    }

    /// Blame as of what's shown: the commit's, or the last commit's carried
    /// onto the text as it is (what differs, not committed).
    func refreshBlame() {
        guard blameShown, let h = fileHistory else { return }
        textView.onBlameClick = { [weak self] i in self?.blameClicked(i) }
        if let i = h.position {
            let r = h.revisions[i]
            if let b = h.blames[r.sha] { textView.blame = b; return }
            let asked = historyAsked
            delegate?.editor(self, fileHistory: .blame(file: path, path: r.path, revision: r.sha)) { [weak self] result in
                guard let self, case .blame(let b) = result else { return }
                self.fileHistory?.blames[r.sha] = b
                if asked == self.historyAsked { self.textView.blame = b }
            }
            return
        }
        let now = rope.string
        if let head = h.head { textView.blame = FileHistory.carry(head.blame, from: head.text, to: now); return }
        let rel = path.hasPrefix(h.root + "/") ? String(path.dropFirst(h.root.count + 1)) : path
        let headName = h.vcs.headName
        delegate?.editor(self, fileHistory: .blame(file: path, path: rel, revision: headName)) { [weak self] result in
            guard let self, case .blame(let b) = result else { return }
            self.delegate?.editor(self, fileHistory: .text(file: self.path, path: rel, revision: headName)) { [weak self] result in
                guard let self, case .text(let text) = result else { return }
                self.fileHistory?.head = (text, b)
                if self.blameShown, self.fileHistory?.position == nil {
                    self.textView.blame = FileHistory.carry(b, from: text, to: self.rope.string)
                }
            }
        }
    }

    /// The last commit moved, or the file was saved: blame now asked again.
    func blameStale() {
        fileHistory?.head = nil
        if blameShown, !scrubbed { refreshBlame() }
    }

    /// A line's commit clicked in the blame: the file as it left it.
    private func blameClicked(_ i: Int) {
        guard let b = textView.blame, b.commits.indices.contains(i) else { return }
        let sha = b.commits[i].sha
        if fileHistory?.shown != true {
            fileHistory?.shown = true
            showStrip()
        }
        func find(_ tries: Int) {
            guard let h = fileHistory else { return }
            if let j = h.revisions.firstIndex(where: { $0.sha == sha || $0.sha.hasPrefix(sha) || sha.hasPrefix($0.sha) }) { return goToRevision(j) }
            guard h.more, tries > 0 else { return flash("That commit isn't among the file's history here") }
            delegate?.editor(self, fileHistory: .log(path: path, skip: h.revisions.count, limit: Self.historyPage)) { [weak self] result in
                guard let self, case let .log(_, _, older, more) = result else { return }
                self.fileHistory?.revisions += older
                self.fileHistory?.more = more
                self.historyStrip.revisions = self.fileHistory?.revisions ?? []
                self.historyStrip.more = more
                find(tries - 1)
            }
        }
        find(5)
    }
}

extension EditorView {
    /// Debugging: the history as it stands, what's shown, and the blame.
    var debugHistory: String {
        guard let h = fileHistory else { return "no history" + (blameShown ? " (blame asked)" : "") }
        let at = h.position.map { "\($0): \(h.revisions[$0].short) \(h.revisions[$0].summary)" } ?? "now"
        let blame = textView.blame.map { b in
            b.lines.map { $0 < 0 ? "·" : String(b.commits[$0].sha.prefix(4)) }.joined(separator: " ")
        } ?? "none"
        return "\(h.vcs) \(h.revisions.count)\(h.more ? "+" : "") commits · at \(at) · editable \(textView.isEditable) · tinted \(scrubbed) · strip \(h.shown) · top \(String(format: "%.1f", topLine)) · lines \(textView.text.lineCount) · top line “\(textView.text.lineText(min(Int(topLine), max(textView.text.lineCount - 1, 0))).trimmingCharacters(in: .whitespaces).prefix(50))”\nmarks \(textView.gutterMarks.map { "\($0.kind)@\($0.line)+\($0.count)" }.joined(separator: ","))\nblame \(blame)"
    }
}
