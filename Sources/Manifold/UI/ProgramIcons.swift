import AppKit
import ManifoldCore

/// The marks of programs run in a terminal (git, docker, vim, node…),
/// from Resources/ProgramIcons, Simple Icons' (CC0; the marks are their
/// makers' trademarks): a terminal's tile and row wear the mark of what's
/// running in it, while it runs (§3.7), as an agent's wear the agent's.
/// One color, tinted as symbols are; wordmarks, too fine to read at a
/// bar's size, left out.
enum ProgramIcons {
    static let prefix = "program:"
    private static let folder = Bundle.main.resourceURL?.appendingPathComponent("ProgramIcons")

    /// Each program by the mark it wears (the file's name, Simple Icons' slug).
    static let marks: [String: String] = {
        let table: [String: [String]] = [
            "git": ["git", "tig", "lazygit", "git-lfs"], "github": ["gh"],
            "docker": ["docker", "docker-compose"], "podman": ["podman"], "kubernetes": ["kubectl", "k9s", "kubectx", "kubens", "minikube", "kind"],
            "vim": ["vim", "vi", "view", "vimdiff"], "neovim": ["nvim"], "gnuemacs": ["emacs", "emacsclient"], "helix": ["hx"], "sublimetext": ["subl"],
            "nodedotjs": ["node"], "npm": ["npm"], "pnpm": ["pnpm"], "yarn": ["yarn"], "bun": ["bun"], "deno": ["deno"],
            "python": ["python", "python3", "ipython", "pip", "pip3", "pytest", "py"], "uv": ["uv", "uvx"],
            "rust": ["cargo", "rustc", "rustup"], "swift": ["swift", "swiftc"], "xcode": ["xcodebuild", "xcrun", "simctl"],
            "ruby": ["ruby", "irb", "bundle", "rake", "gem"], "rubyonrails": ["rails"],
            "openjdk": ["java", "javac", "jshell"], "gradle": ["gradle", "gradlew"], "apachemaven": ["mvn"],
            "gnu": ["make", "gmake"], "cmake": ["cmake", "ctest"], "bazel": ["bazel", "bazelisk"], "terraform": ["terraform", "tofu"],
            "postgresql": ["psql", "postgres", "pg_dump"], "redis": ["redis-cli", "redis-server"], "sqlite": ["sqlite3"],
            "mongodb": ["mongosh", "mongo", "mongod"], "mariadb": ["mariadb"],
            "homebrew": ["brew"], "nixos": ["nix", "nix-shell", "nix-build", "nixos-rebuild"], "tmux": ["tmux"],
            "zig": ["zig"], "julia": ["julia"], "elixir": ["elixir", "iex", "mix"], "dart": ["dart"], "flutter": ["flutter"],
            "ollama": ["ollama"], "vercel": ["vercel"], "heroku": ["heroku"], "googlecloud": ["gcloud", "gsutil"], "flydotio": ["fly", "flyctl"],
            "railway": ["railway"], "render": ["render"], "cloudflare": ["wrangler", "cloudflared"], "supabase": ["supabase"], "stripe": ["stripe"],
            "ansible": ["ansible", "ansible-playbook"], "lua": ["lua", "luajit"], "perl": ["perl"], "r": ["R", "Rscript"],
            "haskell": ["ghc", "ghci", "cabal", "stack"], "ocaml": ["ocaml", "dune", "opam", "utop"], "scala": ["scala", "sbt"], "kotlin": ["kotlin", "kotlinc"],
            "gnubash": ["bash"], "zsh": ["zsh"], "fishshell": ["fish"], "htop": ["htop"], "jupyter": ["jupyter", "jupyter-lab"],
            "vite": ["vite"], "webpack": ["webpack"], "esbuild": ["esbuild"], "turborepo": ["turbo"], "nextdotjs": ["next"], "astro": ["astro"],
            "nginx": ["nginx"], "caddy": ["caddy"],
        ]
        var out: [String: String] = [:]
        for (mark, programs) in table { for p in programs { out[p] = mark } }
        return out
    }()

    /// The mark a program wears, if there's one here.
    static func mark(of program: String) -> String? {
        guard let m = marks[program], let folder, FileManager.default.fileExists(atPath: folder.appendingPathComponent(m + ".svg").path) else { return nil }
        return m
    }

    /// A terminal's symbol while something runs in it that has a mark:
    /// `program:<mark>` (an agent's is the agent's, elsewhere).
    static func symbol(for block: Block) -> String? {
        guard block.kind == .terminal, block.agent == nil, let t = block.terminal, t.pid != nil,
              let running = t.commands?.last, running.ended == nil,
              let program = CommandProgram.program(in: running.text), let m = mark(of: program) else { return nil }
        return prefix + m
    }

    private static var made: [String: NSImage] = [:]

    /// The mark, in a square a symbol of `size` points would fill: a
    /// template, tinted as symbols are.
    static func image(_ mark: String, size: CGFloat) -> NSImage? {
        let key = "\(mark)/\(size)"
        if let i = made[key] { return i }
        guard let url = folder?.appendingPathComponent(mark + ".svg"), let svg = NSImage(contentsOf: url) else { return nil }
        let side = (size * 1.05).rounded()
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            svg.draw(in: r)
            return true
        }
        image.isTemplate = true
        made[key] = image
        return image
    }
}
