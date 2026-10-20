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
          main.innerHTML = html;
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
          window.scrollTo(0, toTop ? 0 : y);
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
          var t1, t2, live = false;
          window.addEventListener('scroll', function () {
            // Where it is, every frame while it moves — for the scrubber to
            // follow live — and, once it has stopped, for keeping.
            if (!live) { live = true; requestAnimationFrame(function () { live = false; post({ scrolling: window.scrollY }); }); }
            clearTimeout(t1); t1 = setTimeout(function () { post({ scroll: window.scrollY }); }, 250);
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

    private static var fontFaces: String {
        guard let fonts = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else { return "" }
        let faces: [(String, String, Int, String)] = [
            ("Monaspace Xenon", "MonaspaceXenon-Regular.otf", 400, "normal"),
            ("Monaspace Xenon", "MonaspaceXenon-Bold.otf", 700, "normal"),
            ("Monaspace Xenon", "MonaspaceRadon-Italic.otf", 400, "italic"),
            ("Monaspace Xenon", "MonaspaceXenon-BoldItalic.otf", 700, "italic"),
            ("Mona Sans", "MonaSans-Regular.otf", 400, "normal"),
            ("Mona Sans", "MonaSans-Italic.otf", 400, "italic"),
            ("Mona Sans", "MonaSans-Medium.otf", 500, "normal"),
            ("Mona Sans", "MonaSans-SemiBold.otf", 600, "normal"),
            ("Mona Sans", "MonaSans-Bold.otf", 700, "normal"),
            ("Mona Sans", "MonaSans-BoldItalic.otf", 700, "italic"),
            ("Tiempos Text", "TiemposText-Regular.otf", 400, "normal"),
            ("Tiempos Text", "TiemposText-RegularItalic.otf", 400, "italic"),
            ("Tiempos Text", "TiemposText-Bold.otf", 700, "normal"),
            ("Tiempos Text", "TiemposText-BoldItalic.otf", 700, "italic"),
            ("Fira Code", "FiraCode-Regular.ttf", 400, "normal"),
            ("Fira Code", "FiraCode-Bold.ttf", 700, "normal"),
        ] + ["Sans", "Mono"].flatMap { kind -> [(String, String, Int, String)] in [
            ("Recursive \(kind)", "Recursive\(kind)LnrSt-Regular.otf", 400, "normal"),
            ("Recursive \(kind)", "Recursive\(kind)LnrSt-Italic.otf", 400, "italic"),
            ("Recursive \(kind)", "Recursive\(kind)LnrSt-Med.otf", 500, "normal"),
            ("Recursive \(kind)", "Recursive\(kind)LnrSt-SemiBold.otf", 600, "normal"),
            ("Recursive \(kind)", "Recursive\(kind)LnrSt-Bold.otf", 700, "normal"),
            ("Recursive \(kind)", "Recursive\(kind)LnrSt-BoldItalic.otf", 700, "italic"),
        ] } + [
            ("Go", "Go-Regular.ttf", 400, "normal"),
            ("Go", "Go-Italic.ttf", 400, "italic"),
            ("Go", "Go-Medium.ttf", 500, "normal"),
            ("Go", "Go-Bold.ttf", 600, "normal"),
            ("Go", "Go-Bold.ttf", 700, "normal"),
            ("Go", "Go-Bold-Italic.ttf", 700, "italic"),
            ("Go Mono", "Go-Mono.ttf", 400, "normal"),
            ("Go Mono", "Go-Mono-Italic.ttf", 400, "italic"),
            ("Go Mono", "Go-Mono-Bold.ttf", 700, "normal"),
            ("Go Mono", "Go-Mono-Bold-Italic.ttf", 700, "italic"),
        ]
        return faces.map { family, file, weight, style in
            """
            @font-face { font-family: "\(family)"; src: url("\(fonts.appendingPathComponent(file).absoluteString)");
              font-weight: \(weight); font-style: \(style); }
            """
        }.joined(separator: "\n")
    }

    /// The theme's fonts, as the CSS variables the page is set in.
    static func themeVariables(_ theme: FontTheme) -> String {
        let css = theme.css
        return "--sans: \(css.sans); --mono: \(css.mono); --mono-features: \(css.features); --sans-features: \(css.sansFeatures);"
    }

    /// Script that sets the page in `theme`'s fonts.
    static func themeScript(_ theme: FontTheme) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [themeVariables(theme)])
        let json = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        return "document.documentElement.style.cssText = \(json);"
    }

    private static var html: String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><base href="file:///">
        <style>
        \(fontFaces)
        :root { color-scheme: light dark; \(themeVariables(.notes)) }
        /* Set as go.dev sets its docs (the Go spec): its colors, sizes and
           spacing, its code (in Menlo, as it comes out on a Mac) and its
           links; the theme's font for the rest. */
        html { background: #ffffff; }
        body {
          margin: 0; color: #202224;
          font: 16px/1.4 var(--sans), -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          font-feature-settings: var(--sans-features);
          -webkit-font-smoothing: antialiased; word-wrap: break-word;
        }
        main { max-width: 75.75rem; margin: 0 auto; padding: 1.5rem 1.5rem 96px; }
        main > :first-child { margin-top: 0; }
        h1, h2, h3, h4, h5, h6 { font-weight: 700; line-height: 1.25; margin: 1.25rem 0 0.75rem; color: #202224; }
        h1 { font-size: 2.25rem; } h2 { font-size: 1.4rem; } h3 { font-size: 1.125rem; }
        h4, h5, h6 { font-size: 1rem; }
        p, ul, ol, blockquote, pre, table, details { margin: 1rem 0; }
        ul, ol { padding-left: 1.8em; } li + li { margin-top: 0.2em; }
        li > input[type=checkbox] { margin: 0 0.45em 0 -1.35em; vertical-align: -1px; }
        ul:has(> li > input[type=checkbox]) { list-style: none; }
        ::-webkit-scrollbar { width: 0; height: 0; }
        a[href^="manifold:"] { display: inline-block; padding: 0 0.55em; border: 0.5px solid rgba(127,127,127,0.5); border-radius: 999px;
          background: rgba(127,127,127,0.12); color: inherit; font-size: 0.9em; line-height: 1.55; vertical-align: 0.05em; }
        a[href^="manifold:"]:hover { text-decoration: none; background: rgba(127,127,127,0.24); }
        a { color: #007d9c; text-decoration: none; } a:hover { text-decoration: underline; }
        code, pre, kbd, samp {
          font-family: Menlo, monospace; font-size: 0.83rem;
          font-feature-settings: var(--mono-features);
        }
        :not(pre) > code { font-size: 0.9em; }
        pre { background: #f8f8f8; color: #202224; padding: 0.5rem 1.75rem; border-radius: 4px; overflow-x: auto; line-height: 1.4; }
        pre code { font-size: 1em; background: none; padding: 0; }
        .codeblock { position: relative; margin: 1em 0; }
        .codeblock > pre { margin: 0; }
        .copy {
          position: absolute; top: 6px; right: 6px; width: 26px; height: 26px;
          display: flex; align-items: center; justify-content: center;
          border: 1px solid #e1e4e8; border-radius: 6px; background: #ffffff; color: #6e7781;
          cursor: pointer; opacity: 0; transition: opacity 0.12s; user-select: none; -webkit-user-select: none; padding: 0;
        }
        .codeblock:hover .copy, .copy.done { opacity: 1; }
        .copy:hover { color: #202224; border-color: #c8ccd1; }
        .copy.done { color: #1a7f37; }
        blockquote { margin-left: 0; padding: 0 1em; color: #57606a; border-left: 3px solid #d8dbe0; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid #e1e4e8; padding: 6px 12px; } th { font-weight: 600; background: #f6f6f4; }
        tr:nth-child(2n) td { background: #f9f9f7; }
        img { max-width: 100%; }
        hr { border: 0; border-top: 1px solid #e1e4e8; margin: 1.6em 0; }
        del { color: #6e7781; }
        .footnotes { font-size: 0.9em; color: #57606a; }
        .missing { color: #a40e26; }
        ::selection { background: #cfe2fb; }
        @media (prefers-color-scheme: dark) {
          html { background: #202224; }
          body, h1, h2, h3, h4, h5, h6 { color: #f0f1f2; }
          blockquote, .footnotes { color: #9d9d98; }
          a { color: #50b7e0; }
          pre { background: #2d2d2d; color: #f0f1f2; }
          .copy { background: #383838; border-color: #4a4a4a; color: #a8a8a8; }
          .copy:hover { color: #f0f1f2; border-color: #5a5a5a; }
          .copy.done { color: #56d364; }
          blockquote { border-left-color: #444441; }
          th, td { border-color: #3a3a38; } th { background: #262625; }
          tr:nth-child(2n) td { background: #212120; }
          hr { border-top-color: #3a3a38; }
          del { color: #8b8b86; }
          .missing { color: #ff7b72; }
          ::selection { background: #264f78; }
        }
        </style></head>
        <body><main id="content"></main></body></html>
        """
    }
}
