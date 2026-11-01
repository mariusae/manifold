import Foundation

/// A language files are written in, as the one table everything that
/// treats a file as code asks (§7.1): whether a text is set as code (the
/// monospaced font to edit, a page of code to view — `Lens.viewRendering`),
/// its grammar for tree-sitter (`SyntaxLanguage`, by `id`), the language
/// server run for it (`LanguageServerConfig.defaults`, by its extensions),
/// the group a folder lists it under, and how a line is commented out.
public struct CodeLanguage: Sendable, Hashable {
    /// What a file in it is besides code: listed under its language, or
    /// among configuration, build files or documents (still set as code).
    public enum Kind: Sendable { case language, data, build, markup }

    public let id: String
    /// Its name, as a folder's group is headed.
    public let name: String
    public let extensions: [String]
    /// Whole names (lowercased) a file in it goes by: Makefile, .zshrc.
    public let names: [String]
    /// What starts a line comment; nil if it has none (its comments are blocks).
    public let comment: String?
    public let kind: Kind

    init(_ id: String, _ name: String, _ extensions: [String], names: [String] = [], comment: String?, kind: Kind = .language) {
        self.id = id
        self.name = name
        self.extensions = extensions
        self.names = names
        self.comment = comment
        self.kind = kind
    }

    public static let all: [CodeLanguage] = [
        CodeLanguage("swift", "Swift", ["swift", "swiftinterface"], comment: "//"),
        CodeLanguage("rust", "Rust", ["rs"], comment: "//"),
        CodeLanguage("go", "Go", ["go"], comment: "//"),
        CodeLanguage("c", "C", ["c", "h"], comment: "//"),
        CodeLanguage("cpp", "C++", ["cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx", "h++", "ipp", "inl"], comment: "//"),
        CodeLanguage("objc", "Objective-C", ["m", "mm"], comment: "//"),
        CodeLanguage("python", "Python", ["py", "pyi", "pyw"], comment: "#"),
        CodeLanguage("cython", "Python", ["pyx", "pxd"], comment: "#"),
        CodeLanguage("ruby", "Ruby", ["rb", "erb", "rake", "gemspec", "ru"],
                     names: ["gemfile", "rakefile", "podfile", "brewfile", "vagrantfile", "fastfile", "guardfile"], comment: "#"),
        CodeLanguage("javascript", "JavaScript", ["js", "mjs", "cjs", "jsx"], comment: "//"),
        CodeLanguage("typescript", "TypeScript", ["ts", "mts", "cts"], comment: "//"),
        CodeLanguage("tsx", "TypeScript", ["tsx"], comment: "//"),
        CodeLanguage("java", "Java", ["java"], comment: "//"),
        CodeLanguage("kotlin", "Kotlin", ["kt", "kts"], comment: "//"),
        CodeLanguage("scala", "Scala", ["scala", "sc"], comment: "//"),
        CodeLanguage("zig", "Zig", ["zig", "zon"], comment: "//"),
        CodeLanguage("lua", "Lua", ["lua"], comment: "--"),
        CodeLanguage("haskell", "Haskell", ["hs", "lhs"], comment: "--"),
        CodeLanguage("ocaml", "OCaml", ["ml", "mli"], comment: nil),
        CodeLanguage("elixir", "Elixir", ["ex", "exs"], comment: "#"),
        CodeLanguage("erlang", "Erlang", ["erl", "hrl"], comment: "%"),
        CodeLanguage("php", "PHP", ["php"], comment: "//"),
        CodeLanguage("csharp", "C#", ["cs"], comment: "//"),
        CodeLanguage("fsharp", "F#", ["fs", "fsi", "fsx"], comment: "//"),
        CodeLanguage("dart", "Dart", ["dart"], comment: "//"),
        CodeLanguage("julia", "Julia", ["jl"], comment: "#"),
        CodeLanguage("r", "R", ["r"], comment: "#"),
        CodeLanguage("perl", "Perl", ["pl", "pm"], comment: "#"),
        CodeLanguage("clojure", "Clojure", ["clj", "cljs", "cljc", "edn"], comment: ";"),
        CodeLanguage("elm", "Elm", ["elm"], comment: "--"),
        CodeLanguage("nim", "Nim", ["nim"], comment: "#"),
        CodeLanguage("odin", "Odin", ["odin"], comment: "//"),
        CodeLanguage("v", "V", ["v"], comment: "//"),
        CodeLanguage("d", "D", ["d"], comment: "//"),
        CodeLanguage("fortran", "Fortran", ["f", "f90", "f95"], comment: "!"),
        CodeLanguage("assembly", "Assembly", ["s", "asm"], comment: ";"),
        CodeLanguage("shell", "Shell", ["sh", "bash", "zsh", "ksh", "command"],
                     names: [".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".zshrc", ".zprofile", ".zshenv", ".zlogin",
                             ".profile", ".envrc"], comment: "#"),
        CodeLanguage("fish", "Shell", ["fish"], comment: "#"),
        CodeLanguage("powershell", "PowerShell", ["ps1", "psm1"], comment: "#"),
        CodeLanguage("sql", "SQL", ["sql"], comment: "--"),
        CodeLanguage("html", "HTML", ["html", "htm", "xhtml"], comment: nil),
        CodeLanguage("css", "CSS", ["css"], comment: nil),
        CodeLanguage("scss", "CSS", ["scss", "sass", "less"], comment: "//"),
        CodeLanguage("vue", "Vue", ["vue"], comment: nil),
        CodeLanguage("svelte", "Svelte", ["svelte"], comment: nil),
        CodeLanguage("nix", "Nix", ["nix"], comment: "#"),
        CodeLanguage("protobuf", "Protocol Buffers", ["proto"], comment: "//"),
        CodeLanguage("thrift", "Thrift", ["thrift"], comment: "//"),
        CodeLanguage("graphql", "GraphQL", ["graphql", "gql"], comment: "#"),
        CodeLanguage("metal", "Metal", ["metal"], comment: "//"),
        CodeLanguage("glsl", "GLSL", ["glsl", "vert", "frag"], comment: "//"),
        CodeLanguage("lisp", "Lisp", ["lisp", "el", "scm", "rkt"], comment: ";"),
        CodeLanguage("tcl", "Tcl", ["tcl"], comment: "#"),
        CodeLanguage("verilog", "Verilog", ["sv"], comment: "//"),
        CodeLanguage("vhdl", "VHDL", ["vhd", "vhdl"], comment: "--"),
        CodeLanguage("solidity", "Solidity", ["sol"], comment: "//"),
        CodeLanguage("gleam", "Gleam", ["gleam"], comment: "//"),
        CodeLanguage("starlark", "Starlark", ["bzl", "star"], comment: "#"),
        CodeLanguage("vim", "Vim Script", ["vim"], names: [".vimrc"], comment: "\""),
        // Data and configuration.
        CodeLanguage("json", "JSON", ["json", "jsonc"], comment: nil, kind: .data),
        CodeLanguage("yaml", "YAML", ["yaml", "yml"], comment: "#", kind: .data),
        CodeLanguage("toml", "TOML", ["toml"], names: ["cargo.lock", "poetry.lock", "pipfile"], comment: "#", kind: .data),
        CodeLanguage("ini", "INI", ["ini", "cfg", "conf", "properties"], comment: "#", kind: .data),
        CodeLanguage("xml", "XML", ["xml"], comment: nil, kind: .data),
        // Build files.
        CodeLanguage("make", "Make", ["mk", "make"], names: ["makefile", "gnumakefile"], comment: "#", kind: .build),
        CodeLanguage("cmake", "CMake", ["cmake"], names: ["cmakelists.txt"], comment: "#", kind: .build),
        CodeLanguage("dockerfile", "Dockerfile", ["dockerfile"], names: ["dockerfile", "containerfile"], comment: "#", kind: .build),
        CodeLanguage("just", "Just", ["just"], names: ["justfile"], comment: "#", kind: .build),
        CodeLanguage("gradle", "Gradle", ["gradle"], comment: "//", kind: .build),
        // Markup that's read as its source: TeX, and patches.
        CodeLanguage("tex", "TeX", ["tex", "sty", "cls"], comment: "%", kind: .markup),
        CodeLanguage("diff", "Diff", ["diff", "patch"], comment: nil, kind: .markup),
    ]

    private static let byExtension: [String: CodeLanguage] = {
        var m: [String: CodeLanguage] = [:]
        for l in all { for e in l.extensions where m[e] == nil { m[e] = l } }
        return m
    }()

    private static let byName: [String: CodeLanguage] = {
        var m: [String: CodeLanguage] = [:]
        for l in all { for n in l.names where m[n] == nil { m[n] = l } }
        return m
    }()

    /// The file's language, by its whole name, else its extension; nil
    /// if it isn't code (prose, an image, a name not in the table).
    public static func forPath(_ path: String) -> CodeLanguage? {
        let name = path.lastPathComponent.lowercased()
        if let l = byName[name] { return l }
        let ext = name.pathExtension
        return ext.isEmpty ? nil : byExtension[ext]
    }

    public static func named(_ id: String) -> CodeLanguage? { all.first { $0.id == id } }

    /// The extensions of the languages named, for a language server's table.
    public static func extensions(_ ids: String...) -> [String] { ids.flatMap { named($0)?.extensions ?? [] } }
}
