import Foundation
import ManifoldCore

/// The page Markdown is shown in: a shell with the styles, into which each
/// rendering is put by `script`, so the page (and its scroll position)
/// stays put as the file changes.
enum MarkdownPage {
    /// The shell, written once to a temporary file: WebKit only lets a page
    /// read local files (images beside the document, our fonts) when the
    /// page itself was loaded from a file.
    static let shell: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-markdown-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("page.html")
        try? html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }()

    /// Defines the functions the view calls; evaluated before each call, as
    /// the page's own scripts are off.
    static let script = """
        window.manifoldRender = function (html, base, toTop) {
          document.querySelector('base').href = base;
          var y = window.scrollY;
          var main = document.getElementById('content');
          // An agent's conversation: what was unfolded kept so, and, at its
          // end (or shown for the first time), kept at its end as it grows.
          var talk = main.querySelector('.mf-conversation');
          var atEnd = !talk || window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 24;
          var open = {};
          main.querySelectorAll('details[id][open]').forEach(function (d) { open[d.id] = true; });
          main.innerHTML = html;
          main.querySelectorAll('details[id]').forEach(function (d) { if (open[d.id]) d.open = true; });
          if (main.querySelector('.mf-conversation') && atEnd) {
            requestAnimationFrame(function () { window.scrollTo(0, document.documentElement.scrollHeight); });
          }
          // GitHub's ids for headings, so links to them work.
          var seen = {};
          main.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(function (h) {
            var slug = h.textContent.trim().toLowerCase().replace(/[^\\w\\- ]+/g, '').replace(/ /g, '-');
            var n = seen[slug] || 0;
            seen[slug] = n + 1;
            h.id = n ? slug + '-' + n : slug;
          });
          // A copy button on each code block, shown on hover, in a wrapper
          // so it stays put as a long line scrolls under it.
          var copyIcon = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="5.5" y="5.5" width="8" height="8.5" rx="1.6"/><path d="M10.5 3.6V3.2c0-.9-.7-1.6-1.6-1.6H3.6C2.7 1.6 2 2.3 2 3.2v6.2c0 .9.7 1.6 1.6 1.6H4"/></svg>';
          var doneIcon = '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M3 8.5l3.2 3L13 4.5"/></svg>';
          main.querySelectorAll('pre').forEach(function (pre) {
            var wrap = document.createElement('div');
            wrap.className = 'codeblock';
            pre.parentNode.insertBefore(wrap, pre);
            wrap.appendChild(pre);
            var b = document.createElement('button');
            b.className = 'copy';
            b.title = 'Copy';
            b.setAttribute('aria-label', 'Copy');
            b.innerHTML = copyIcon;
            b.addEventListener('mousedown', function (e) { e.preventDefault(); });
            b.addEventListener('click', function (e) {
              e.preventDefault();
              var code = pre.querySelector('code') || pre;
              try { window.webkit.messageHandlers.manifoldState.postMessage({ copy: code.textContent }); } catch (err) {}
              b.innerHTML = doneIcon;
              b.classList.add('done');
              clearTimeout(b.manifoldTimer);
              b.manifoldTimer = setTimeout(function () { b.innerHTML = copyIcon; b.classList.remove('done'); }, 1200);
            });
            wrap.appendChild(b);
          });
          window.manifoldPendingDiagrams = window.manifoldDiagrams();
          window.scrollTo(0, toTop ? 0 : y);
        };
        // Mermaid's diagrams (```mermaid, or a block that starts with a
        // diagram's kind, as `flowchart LR`) drawn in place of their code by
        // Pele, once it's here: how many wait on it, else 0. Pele draws in
        // a fraction of a millisecond, at once, so each is drawn again with
        // the page — mounted, so it fits its tile's width as that changes.
        var manifoldDiagramKinds = ['flowchart', 'flowchart-elk', 'graph', 'sequenceDiagram', 'classDiagram', 'classDiagram-v2',
          'stateDiagram', 'stateDiagram-v2', 'erDiagram', 'journey', 'gantt', 'pie', 'quadrantChart', 'requirementDiagram', 'gitGraph',
          'mindmap', 'timeline', 'sankey', 'sankey-beta', 'xychart', 'xychart-beta', 'block', 'block-beta', 'packet', 'packet-beta',
          'kanban', 'architecture', 'architecture-beta', 'radar-beta', 'treemap', 'treemap-beta', 'venn-beta', 'ishikawa-beta',
          'wardley-beta', 'cynefin-beta', 'swimlane', 'swimlane-beta', 'usecase', 'usecase-beta', 'eventmodeling', 'treeView-beta',
          'railroad-beta', 'railroad-ebnf-beta', 'railroad-abnf-beta', 'railroad-peg-beta', 'agentflow-beta',
          'C4Context', 'C4Container', 'C4Component', 'C4Dynamic', 'C4Deployment'];
        function manifoldDiagramSource(code) {
          var cls = code.className || '', text = code.textContent;
          if (cls.indexOf('language-mermaid') >= 0) return text;
          if (cls) return null;
          var first = text.trim().split(/\\s/)[0];
          if (manifoldDiagramKinds.indexOf(first) < 0) return null;
          // A block that only looks like one (a word that starts some prose) left as code.
          return !window.pele || pele.supports(text) ? text : null;
        }
        window.manifoldDiagrams = function () {
          var found = [];
          document.querySelectorAll('#content .codeblock').forEach(function (wrap) {
            var pre = wrap.querySelector('pre'), code = pre && pre.querySelector('code');
            var src = code && manifoldDiagramSource(code);
            if (src) found.push([wrap, pre, src]);
          });
          // Those drawn before, gone with the page they were on, let go.
          window.manifoldMounted = (window.manifoldMounted || []).filter(function (m) {
            if (m.el.isConnected) return true;
            m.mounted.destroy();
            return false;
          });
          if (!found.length) return 0;
          if (!window.pele) return found.length;
          found.forEach(function (f) {
            var wrap = f[0], pre = f[1], src = f[2];
            // Typed with smart punctuation (curly quotes, a dash for an
            // arrow's shaft), it's tried again as plain, if it didn't parse.
            var plain = src.replace(/[\\u201C\\u201D]/g, '"').replace(/[\\u2018\\u2019]/g, "'").replace(/[\\u2014\\u2013]/g, '--');
            var text = src;
            try {
              pele.parse(src);
            } catch (err) {
              try { pele.parse(plain); text = plain; } catch (_) {
                // Left as code, with why it couldn't be drawn (once: the
                // page is drawn again as it's typed in).
                var note = wrap.querySelector('.diagram-error') || wrap.appendChild(document.createElement('div'));
                note.className = 'diagram-error';
                // Pele's message: where, the line with a caret, then why.
                var said = String((err && err.message) || err).split('\\n').filter(function (l) { return l.trim(); });
                var why = said.length > 1 ? said[said.length - 1] : said[0];
                note.textContent = 'Not drawn: ' + why + (err && err.line ? ' (line ' + err.line + ')' : '');
                return;
              }
            }
            // Its kind, as its first line says it (`flowchart LR`), past
            // any front matter and comments — pele.run's card's label.
            var lines = text.split('\\n'), i = 0, kind = '';
            if (lines[0] && lines[0].trim() === '---') { i = 1; while (i < lines.length && lines[i].trim() !== '---') i++; i++; }
            for (; i < lines.length; i++) { var l = lines[i].trim(); if (l && l.indexOf('%%') !== 0) { kind = l; break; } }
            // On a card, as pele.run shows them: its kind, then it.
            var card = document.createElement('figure');
            card.className = 'diagram';
            var pos = pre.getAttribute('data-sourcepos');
            if (pos) card.setAttribute('data-sourcepos', pos);
            var label = document.createElement('figcaption');
            label.className = 'diagram-kind';
            label.textContent = kind;
            var el = document.createElement('div');
            el.className = 'diagram-figure';
            card.appendChild(label);
            card.appendChild(el);
            if (wrap.parentNode) wrap.parentNode.replaceChild(card, wrap);
            try {
              window.manifoldMounted.push({ el: el, mounted: pele.mount(el, text) });
            } catch (err) {
              card.parentNode.replaceChild(wrap, card);
              var note2 = wrap.querySelector('.diagram-error') || wrap.appendChild(document.createElement('div'));
              note2.className = 'diagram-error';
              note2.textContent = 'Not drawn: ' + String((err && err.message) || err).split('\\n')[0];
            }
          });
          return 0;
        };
        window.manifoldScrollTo = function (id) {
          var e = document.getElementById(id) || document.getElementsByName(id)[0];
          if (e) e.scrollIntoView({ block: 'start' });
        };
        // The selection as offsets into the content's text, so it can be
        // put back after the page is rendered again.
        window.manifoldOffsets = function () {
          var sel = window.getSelection();
          if (!sel || sel.rangeCount == 0 || sel.isCollapsed || !sel.toString().trim()) return null;
          var r = sel.getRangeAt(0), main = document.getElementById('content');
          function offsetOf(node, off) {
            var w = document.createTreeWalker(main, NodeFilter.SHOW_TEXT), total = 0, n;
            while ((n = w.nextNode())) { if (n === node) return total + off; total += n.data.length; }
            return total;
          }
          function point(node, off) {
            if (node.nodeType === 3) return offsetOf(node, off);
            // An element boundary: before its off-th child, or past its last.
            if (off < node.childNodes.length) {
              var w = document.createTreeWalker(node.childNodes[off], NodeFilter.SHOW_TEXT), t = w.nextNode();
              if (t) return offsetOf(t, 0);
              var after = node.childNodes[off];
              while (after && !(after.nodeType === 3)) { after = after.nextSibling || (after.parentNode === main ? null : after.parentNode.nextSibling); }
              return after ? offsetOf(after, 0) : offsetOf(node, 0);
            }
            var w2 = document.createTreeWalker(node, NodeFilter.SHOW_TEXT), last = null, n;
            while ((n = w2.nextNode())) last = n;
            return last ? offsetOf(last, last.data.length) : offsetOf(node, 0);
          }
          return [point(r.startContainer, r.startOffset), point(r.endContainer, r.endOffset)];
        };
        // Places in the text (lines from 0, fractions within) and on the
        // page, through the lines each block element came from.
        function manifoldPos(el) {
          var m = /^(\\d+):\\d+-(\\d+):\\d+$/.exec(el.getAttribute('data-sourcepos') || '');
          return m ? [parseInt(m[1], 10), parseInt(m[2], 10)] : null;
        }
        // The line at the top of the window: within the innermost element
        // across it, as far down it as the top is; else the next one's.
        window.manifoldTopLine = function () {
          var els = document.querySelectorAll('[data-sourcepos]'), best = null, span = 1e9, next = null;
          for (var i = 0; i < els.length; i++) {
            var p = manifoldPos(els[i]); if (!p) continue;
            var r = els[i].getBoundingClientRect();
            if (r.top <= 0 && r.bottom > 0) { if (p[1] - p[0] <= span) { best = [r, p]; span = p[1] - p[0]; } }
            else if (r.top > 0 && !next) next = p;
          }
          if (best) {
            var f = best[0].height > 0 ? -best[0].top / best[0].height : 0;
            return best[1][0] - 1 + f * (best[1][1] - best[1][0] + 1);
          }
          return next ? next[0] - 1 : 0;
        };
        // The window scrolled so `line` is at its top: as far down the
        // innermost element it's in, or at the next element after it.
        window.manifoldToLine = function (line) {
          window.manifoldAnchor = line;
          var L = line + 1, whole = Math.floor(L), els = document.querySelectorAll('[data-sourcepos]');
          var best = null, span = 1e9, next = null, nextStart = 1e9;
          for (var i = 0; i < els.length; i++) {
            var p = manifoldPos(els[i]); if (!p) continue;
            if (p[0] <= whole && whole <= p[1]) { if (p[1] - p[0] <= span) { best = [els[i], p]; span = p[1] - p[0]; } }
            else if (p[0] > whole && p[0] < nextStart) { next = els[i]; nextStart = p[0]; }
          }
          if (best) {
            var r = best[0].getBoundingClientRect(), f = (L - best[1][0]) / (best[1][1] - best[1][0] + 1);
            window.scrollTo(0, window.scrollY + r.top + f * r.height);
          } else if (next) {
            window.scrollTo(0, window.scrollY + next.getBoundingClientRect().top);
          } else if (line > 0) {
            window.scrollTo(0, document.body.scrollHeight);
          }
        };
        window.manifoldRestore = function (y, start, end) {
          // Selection changes right after are the page settling (focus
          // coming and going), not the reader's: not kept.
          window.manifoldQuiet = Date.now() + 1500;
          if (y != null) window.scrollTo(0, y);
          if (start != null && end != null && end > start) {
            var main = document.getElementById('content');
            function at(offset) {
              var w = document.createTreeWalker(main, NodeFilter.SHOW_TEXT), total = 0, n, last = null;
              while ((n = w.nextNode())) {
                if (total + n.data.length >= offset) return [n, offset - total];
                total += n.data.length; last = n;
              }
              return last ? [last, last.data.length] : null;
            }
            function apply() {
              var a = at(start), b = at(end);
              if (!a || !b) return;
              var range = document.createRange();
              range.setStart(a[0], a[1]); range.setEnd(b[0], b[1]);
              var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range);
            }
            apply();
            // The view settling into its window can clear it: put back.
            [300, 1200].forEach(function (ms) {
              setTimeout(function () { if (!window.getSelection().toString()) apply(); }, ms);
            });
          }
        };
        // Told of scrolling and selecting, a moment after each stops.
        window.manifoldWatch = function () {
          if (window.manifoldWatching) return;
          window.manifoldWatching = true;
          function post(m) { try { window.webkit.messageHandlers.manifoldState.postMessage(m); } catch (e) {} }
          var t1, t2, live = false, resizing = false, lastW = window.innerWidth;
          // Wider or narrower (the tile's sidebar going or coming, the
          // window resized): the line at its top kept there as the text
          // rewraps — and a place just gone to, before the width changed,
          // gone to again at the new one. Not an agent's conversation,
          // which keeps to its end.
          window.addEventListener('resize', function () {
            if (window.innerWidth === lastW) return;
            lastW = window.innerWidth;
            if (document.querySelector('.mf-conversation') || window.manifoldAnchor == null) return;
            resizing = true;
            manifoldToLine(window.manifoldAnchor);
            requestAnimationFrame(function () { resizing = false; });
          });
          window.addEventListener('scroll', function () {
            // Where it is, every frame while it moves — for the scrubber to
            // follow live — and, once it has stopped, for keeping.
            if (!live) { live = true; requestAnimationFrame(function () { live = false; post({ scrolling: window.scrollY }); if (!resizing) window.manifoldAnchor = manifoldTopLine(); }); }
            clearTimeout(t1); t1 = setTimeout(function () { post({ scroll: window.scrollY }); }, 250);
          });
          // The pointer onto a block's link, or off it: one to a block
          // that's gone is told by the pointer.
          var hovered = '';
          document.addEventListener('mouseover', function (e) {
            var a = e.target.closest && e.target.closest('a[href^="manifold:"]');
            var h = a ? a.getAttribute('href') : '';
            if (h !== hovered) { hovered = h; post({ hover: h }); }
          });
          document.addEventListener('selectionchange', function () {
            if (window.manifoldQuiet && Date.now() < window.manifoldQuiet) return;
            clearTimeout(t2); t2 = setTimeout(function () {
              var o = manifoldOffsets();
              post(o ? { selStart: o[0], selEnd: o[1] } : { selStart: -1, selEnd: -1 });
            }, 250);
          });
        };

        """

    /// The theme's fonts, as the CSS variables the page is set in.
    static func themeVariables(_ theme: FontTheme) -> String {
        let css = theme.css
        return "--sans: \(css.sans); --mono: \(css.mono); --mono-features: \(css.features); --sans-features: \(css.sansFeatures); " + theme.cssExtras
    }

    /// Script that sets the page in `theme`'s fonts.
    static func themeScript(_ theme: FontTheme) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [themeVariables(theme)])
        let json = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        return "document.documentElement.style.cssText = \(json);"
    }

    /// Script that sets the page in the theme's colours.
    static var paletteScript: String {
        let data = try! JSONSerialization.data(withJSONObject: [Palette.current.pageCSS])
        let json = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        return "document.getElementById('palette').textContent = \(json);"
    }

    private static var html: String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><base href="file:///">
        <style>
        :root { color-scheme: light dark; \(themeVariables(.apple)) }
        </style><style id="palette">\(Palette.current.pageCSS)</style><style>
        /* Set as go.dev sets its docs (the Go spec): its colors, sizes and
           spacing and its links; the theme's fonts for its text and its
           code (Menlo where a theme has none of its own). */
        html { background: var(--page-background); }
        body {
          margin: 0; color: var(--page-text);
          font: var(--read-weight, 400) var(--read-size, 16px)/var(--read-leading, 1.4) var(--sans), -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          font-feature-settings: var(--sans-features); letter-spacing: var(--read-tracking, normal);
          -webkit-font-smoothing: antialiased; word-wrap: break-word;
        }
        main { max-width: var(--read-measure, 75.75rem); margin: 0 auto; padding: 1.5rem 1.5rem 96px; }
        main > :first-child { margin-top: 0; }
        strong, b { font-weight: var(--read-bold, bolder); }
        h1, h2, h3, h4, h5, h6 { font-weight: var(--read-heading, 700); line-height: 1.25; margin: 1.25rem 0 0.75rem; color: var(--page-strong); }
        h1 { font-size: 2.25rem; } h2 { font-size: 1.4rem; } h3 { font-size: 1.125rem; }
        h4, h5, h6 { font-size: 1rem; }
        p, ul, ol, blockquote, pre, table, details { margin: var(--read-gap, 1rem) 0; }
        ul, ol { padding-left: 1.8em; } li + li { margin-top: 0.2em; }
        li > input[type=checkbox] { margin: 0 0.45em 0 -1.35em; vertical-align: -1px; }
        ul:has(> li > input[type=checkbox]) { list-style: none; }
        ::-webkit-scrollbar { width: 0; height: 0; }
        a[href^="manifold:"] { display: inline-block; padding: 0 0.55em; border: 0.5px solid rgba(127,127,127,0.5); border-radius: 999px;
          background: rgba(127,127,127,0.12); color: inherit; font-size: 0.9em; line-height: 1.55; vertical-align: 0.05em; }
        a[href^="manifold:"]:hover { text-decoration: none; background: rgba(127,127,127,0.24); }
        a.mcard[href^="manifold:"] { display: flex; gap: 0.8em; max-width: 30rem; margin: 0.4em 0; padding: 0.6em 0.8em; border-radius: 10px;
          border: 0.5px solid rgba(127,127,127,0.45); background: rgba(127,127,127,0.07); font-size: 0.88em; line-height: 1.4; vertical-align: baseline; }
        a.mcard[href^="manifold:"]:hover { background: rgba(127,127,127,0.14); }
        .mcard-body { flex: 1; min-width: 0; display: flex; flex-direction: column; }
        .mcard-head { display: flex; align-items: center; gap: 0.45em; }
        .mcard-head img { width: 1.05em; height: 1.05em; flex: none; }
        .mcard-title { font-weight: 600; flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .mcard-note { flex: none; opacity: 0.6; font-size: 0.92em; }
        .mcard-note.failed { color: var(--page-failed); opacity: 1; } .mcard-note.running { color: var(--page-running); opacity: 1; } .mcard-note.attention { color: var(--page-attention); opacity: 1; }
        .mcard-place, .mcard-line { opacity: 0.68; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .mcard-line.code { font-family: var(--mono), Menlo, monospace; font-size: 0.9em; }
        .mcard-thumb { width: 5.5em; max-height: 5.5em; border-radius: 5px; object-fit: cover; flex: none; }
        a { color: var(--page-link); text-decoration: none; } a:hover { text-decoration: underline; }
        code, pre, kbd, samp {
          font-family: var(--mono), Menlo, monospace; font-size: calc(0.83rem * var(--mono-scale, 1));
          font-feature-settings: var(--mono-features); font-weight: var(--mono-weight, 400); letter-spacing: var(--mono-tracking, normal);
        }
        :not(pre) > code { font-size: 0.9em; }
        pre { background: var(--page-code); color: var(--page-code-text); padding: 0.5rem 1.75rem; border-radius: 4px; overflow-x: auto; line-height: 1.4; }
        pre code { font-size: 1em; background: none; padding: 0; }
        .codeblock { position: relative; margin: 1em 0; }
        .codeblock > pre { margin: 0; }
        .copy {
          position: absolute; top: 6px; right: 6px; width: 26px; height: 26px;
          display: flex; align-items: center; justify-content: center;
          border: 1px solid var(--page-copy-edge); border-radius: 6px; background: var(--page-copy); color: var(--page-copy-text);
          cursor: pointer; opacity: 0; transition: opacity 0.12s; user-select: none; -webkit-user-select: none; padding: 0;
        }
        .codeblock:hover .copy, .copy.done { opacity: 1; }
        /* Diagrams on a card as a code block's ground is, in the theme:
           its text, its link for an accent, its failed for what's
           critical, shades between its text and that ground for surfaces
           and borders, its terminal's colours for a chart's series; its
           fonts, the page's and its code's. */
        .diagram {
          margin: var(--read-gap, 1rem) 0; padding: 0 16px 20px; border-radius: 8px; overflow: hidden;
          background: var(--pele-bg); position: relative;
          --pele-font: var(--sans), -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          --pele-font-mono: var(--mono), Menlo, monospace;
          --pele-radius: 4px;
          --pele-bg: var(--page-code);
          --pele-fg: var(--page-text);
          --pele-muted: color-mix(in srgb, var(--page-text) 60%, var(--page-code));
          --pele-line: color-mix(in srgb, var(--page-text) 85%, var(--page-code));
          --pele-surface: color-mix(in srgb, var(--page-text) 7%, var(--page-code));
          --pele-surface-alt: color-mix(in srgb, var(--page-text) 13%, var(--page-code));
          --pele-border: color-mix(in srgb, var(--page-text) 24%, var(--page-code));
          --pele-accent: var(--page-link);
          --pele-critical: var(--page-failed);
          --pele-series-1: var(--page-series-1); --pele-series-2: var(--page-series-2);
          --pele-series-3: var(--page-series-3); --pele-series-4: var(--page-series-4);
          --pele-series-5: var(--page-series-5); --pele-series-6: var(--page-series-6);
          --pele-series-7: var(--page-series-7); --pele-series-8: var(--page-series-8);
        }
        .diagram-kind { font-family: var(--pele-font-mono); font-size: calc(0.78rem * var(--mono-scale, 1)); line-height: 2.4;
          color: var(--pele-muted); margin: 0 0 6px;
          white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .diagram-figure { position: relative; display: grid; justify-items: center; }
        .diagram-figure svg { max-width: 100%; height: auto; }
        .diagram-error { margin-top: 0.4em; font-size: 0.85em; color: var(--page-diagram-error); }
        .copy:hover { color: var(--page-copy-hover-text); border-color: var(--page-copy-hover-edge); }
        .copy.done { color: var(--page-copy-done); }
        blockquote { margin-left: 0; padding: 0 1em; color: var(--page-quote); border-left: 3px solid var(--page-quote-rule); }
        /* An agent's conversation (§3.8): what you asked in the technical
           face, as typed; what it did on the way folded to a line; what it
           said as the page is, in the reading face. */
        .mf-turn { margin: 0 0 2.4em; }
        .mf-turn + .mf-turn { border-top: 1px solid var(--page-rule); padding-top: 1.6em; }
        /* The technical face at its own weight throughout: Whitney's run
           300 to 450, and CSS's 400, unasked, was its Bold. */
        pre.mf-prompt { font-family: var(--tech), -apple-system, sans-serif; font-weight: var(--tech-weight, 400);
          font-size: calc(0.86rem * var(--tech-scale, 1)); line-height: 1.45; white-space: pre-wrap; word-wrap: break-word;
          background: none; border: none; border-left: 3px solid var(--page-quote-rule); border-radius: 0;
          padding: 0.1em 0 0.1em 0.9em; margin: 0 0 1.1em; color: var(--page-strong); }
        pre.mf-prompt.mf-queued { color: var(--page-quote); border-left-style: dashed; }
        details.mf-steps { font-family: var(--tech), -apple-system, sans-serif; font-weight: var(--tech-weight, 400); font-size: calc(0.8rem * var(--tech-scale, 1));
          color: var(--page-quote); margin: 0 0 1em; }
        details.mf-steps summary { cursor: default; list-style: none; }
        details.mf-steps summary::-webkit-details-marker { display: none; }
        details.mf-steps summary::before { content: "›"; display: inline-block; width: 1em; transition: transform 0.12s; }
        details.mf-steps[open] summary::before { transform: rotate(90deg); }
        details.mf-steps[open] { padding-bottom: 0.4em; border-bottom: 1px solid var(--page-rule); }
        details.mf-steps p, details.mf-steps ul { margin: 0.5em 0 0.5em 1em; }
        p.mf-asked { font-family: var(--tech), -apple-system, sans-serif; font-weight: var(--tech-weight, 400); font-size: calc(0.86rem * var(--tech-scale, 1));
          color: var(--page-strong); border-left: 3px solid var(--page-quote-rule); padding-left: 0.9em; margin: 0 0 1.1em; }
        p.mf-event { font-family: var(--tech), -apple-system, sans-serif; font-weight: var(--tech-weight, 400); font-size: calc(0.8rem * var(--tech-scale, 1));
          color: var(--page-quote); margin: 0 0 1em; }
        .mf-aside { color: var(--page-quote); }
        .mf-aside > :first-child { margin-top: 0; }
        .mf-dots { display: inline-flex; gap: 3px; margin-right: 0.55em; vertical-align: 0.12em; }
        .mf-dots i { width: 4px; height: 4px; border-radius: 50%; background: currentColor; opacity: 0.35;
          animation: mf-dot 1.2s infinite linear; }
        .mf-dots i:nth-child(2) { animation-delay: 0.2s; } .mf-dots i:nth-child(3) { animation-delay: 0.4s; }
        @keyframes mf-dot { 0% { opacity: 0.35; } 17% { opacity: 1; } 45%, 100% { opacity: 0.35; } }
        @media (prefers-reduced-motion: reduce) { .mf-dots i { animation: none; opacity: 0.7; } }
        .mf-standing, .mf-earlier { font-family: var(--tech), -apple-system, sans-serif; font-weight: var(--tech-weight, 400); font-size: calc(0.8rem * var(--tech-scale, 1));
          color: var(--page-quote); }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid var(--page-rule); padding: 6px 12px; } th { font-weight: 600; background: var(--page-table-head); }
        tr:nth-child(2n) td { background: var(--page-table-stripe); }
        img { max-width: 100%; }
        hr { border: 0; border-top: 1px solid var(--page-rule); margin: 1.6em 0; }
        del { color: var(--page-struck); }
        .footnotes { font-size: 0.9em; color: var(--page-quote); }
        .missing { color: var(--page-missing); }
        ::selection { background: var(--page-selection); }
        /* In the dark (the colours above its own there): the body a step
           down from white, against glare over a long read; headings and
           bold brighter, to do emphasis's work. */
        @media (prefers-color-scheme: dark) {
          strong, b { color: var(--page-strong); }
        }
        </style></head>
        <body><main id="content"></main></body></html>
        """
    }
}
