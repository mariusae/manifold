import Foundation

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

        """

    private static var fontFaces: String {
        guard let fonts = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else { return "" }
        let faces: [(String, String, Int, String)] = [
            ("Monaspace Xenon", "MonaspaceXenon-Regular.otf", 400, "normal"),
            ("Monaspace Xenon", "MonaspaceXenon-Bold.otf", 700, "normal"),
            ("Monaspace Xenon", "MonaspaceRadon-Italic.otf", 400, "italic"),
            ("Monaspace Xenon", "MonaspaceXenon-BoldItalic.otf", 700, "italic"),
        ]
        return faces.map { family, file, weight, style in
            """
            @font-face { font-family: "\(family)"; src: url("\(fonts.appendingPathComponent(file).absoluteString)");
              font-weight: \(weight); font-style: \(style); }
            """
        }.joined(separator: "\n")
    }

    private static var html: String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><base href="file:///">
        <style>
        \(fontFaces)
        :root { color-scheme: light; }
        html { background: #fcfcfb; }
        body {
          margin: 0; color: #24292f;
          font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
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
        a { color: #0969da; text-decoration: none; } a:hover { text-decoration: underline; }
        code, pre, kbd, samp {
          font-family: "Monaspace Xenon", Menlo, monospace; font-size: 0.86em;
          font-feature-settings: "calt", "ss02", "ss03", "ss07", "ss08";
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
        </style></head>
        <body><main id="content"></main></body></html>
        """
    }
}
