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
        html { background: #fcfcfb; }
        body {
          margin: 0; color: #24292f;
          font: 15px/1.6 var(--sans), -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          font-feature-settings: var(--sans-features);
          -webkit-font-smoothing: antialiased; word-wrap: break-word;
        }
        main { max-width: 780px; margin: 0 auto; padding: 28px 40px 96px; }
        main > :first-child { margin-top: 0; }
        h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 1.5em 0 0.6em; }
        h1 { font-size: 1.9em; padding-bottom: 0.25em; border-bottom: 1px solid #e4e6e9; }
        h2 { font-size: 1.45em; padding-bottom: 0.2em; border-bottom: 1px solid #eceef0; }
        h3 { font-size: 1.2em; } h4 { font-size: 1em; } h5, h6 { font-size: 0.9em; color: #57606a; }
        p, ul, ol, blockquote, pre, table, details { margin: 0 0 1em; }
        ul, ol { padding-left: 1.8em; } li + li { margin-top: 0.2em; }
        li > input[type=checkbox] { margin: 0 0.45em 0 -1.35em; vertical-align: -1px; }
        ul:has(> li > input[type=checkbox]) { list-style: none; }
        ::-webkit-scrollbar { width: 0; height: 0; }
        a[href^="manifold:"] { display: inline-block; padding: 0 0.55em; border: 0.5px solid rgba(127,127,127,0.5); border-radius: 999px;
          background: rgba(127,127,127,0.12); color: inherit; font-size: 0.9em; line-height: 1.55; vertical-align: 0.05em; }
        a[href^="manifold:"]:hover { text-decoration: none; background: rgba(127,127,127,0.24); }
        a { color: #0969da; text-decoration: none; } a:hover { text-decoration: underline; }
        code, pre, kbd, samp {
          font-family: var(--mono), ui-monospace, Menlo, monospace; font-size: 0.86em;
          font-feature-settings: var(--mono-features);
        }
        :not(pre) > code { background: #eff0ee; padding: 0.12em 0.35em; border-radius: 4px; }
        pre { background: #f3f3f1; padding: 12px 14px; border-radius: 8px; overflow-x: auto; line-height: 1.45; }
        pre code { font-size: 1em; background: none; padding: 0; }
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
          html { background: #1c1c1b; }
          body { color: #e3e3df; }
          h1 { border-bottom-color: #3a3a38; } h2 { border-bottom-color: #333331; }
          h5, h6, blockquote, .footnotes { color: #9d9d98; }
          a { color: #58a6ff; }
          :not(pre) > code { background: #2c2c2a; }
          pre { background: #252524; }
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
