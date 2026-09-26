import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Markdown to HTML, as GitHub renders it (cmark-gfm): tables, task lists,
/// strikethrough, autolinks, and footnotes. Raw HTML passes through, less
/// the tags GitHub filters (script, iframe, and the like).
public enum MarkdownRenderer {
    private static let extensions = ["table", "strikethrough", "autolink", "tagfilter", "tasklist"]

    public static func html(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_UNSAFE | CMARK_OPT_GITHUB_PRE_LANG | CMARK_OPT_FOOTNOTES
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in extensions {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
        let text = stripFrontMatter(markdown)
        var utf8 = Array(text.utf8)
        utf8.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                cmark_parser_feed(parser, $0, buf.count)
            }
        }
        guard let doc = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(doc) }
        guard let out = cmark_render_html(doc, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(out) }
        return String(cString: out)
    }

    /// The document without YAML front matter (a leading block between two
    /// `---` lines), which is metadata rather than text.
    public static func stripFrontMatter(_ markdown: String) -> String {
        guard markdown.hasPrefix("---\n") || markdown.hasPrefix("---\r\n") else { return markdown }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            return lines[(i + 1)...].joined(separator: "\n")
        }
        return markdown
    }
}
