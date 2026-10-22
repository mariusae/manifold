import Foundation
import ManifoldCore

/// Where the server looks for the tools it runs (git, sl, rg, language
/// servers): the PATH it was started with — an app's, from the Finder,
/// is short — and then the folders tools are commonly installed in, those
/// that are there (Homebrew's, Linuxbrew's, a user's own). Set once, as
/// the server starts, before it runs anything.
enum ToolPath {
    static func extend() {
        let home = NSHomeDirectory()
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        for d in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin",
                  home + "/.local/bin", home + "/bin", home + "/.cargo/bin", "/snap/bin", "/usr/bin", "/bin"]
        where !dirs.contains(d) && FileManager.default.fileExists(atPath: d) {
            dirs.append(d)
        }
        setenv("PATH", dirs.joined(separator: ":"), 1)
    }
}

/// Sapling's Interactive Smartlog (§7.6): `sl web`, which serves it on the
/// host's own loopback (one server for every repository, each its own
/// page), started in a repository — or the one already running found — and
/// where it serves that repository's page given back.
enum Smartlog {
    /// The URL (with its token and the repository) or why not, on a thread
    /// of its own.
    /// The ports tried, in turn: the usual one first. A port another user's
    /// server (or anything else) has is passed over; ours on it is used. The
    /// same order every time, so the same port is found again.
    static let ports = Array(3011...3030)

    static func start(in repo: String, done: @escaping (String?, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var why = "sl web failed"
            for port in ports {
                let out: Data, status: Int32
                do {
                    (out, status) = try Child.run(["sl", "--cwd", repo, "web", "--json", "--no-open", "--port", "\(port)"], timeout: 60, quiet: true)
                } catch {
                    return done(nil, "Sapling (sl) isn't installed on this host")
                }
                struct Answer: Decodable { let url: String }
                // The JSON is the last line (sl may say other things first).
                let said = String(decoding: out, as: UTF8.self)
                let last = said.split(separator: "\n").last.map(String.init) ?? ""
                if status == 0, let answer = try? JSONDecoder().decode(Answer.self, from: Data(last.utf8)) {
                    return done(answer.url, nil)
                }
                why = said.trimmingCharacters(in: .whitespacesAndNewlines)
                // Someone else's port: the next. Anything else is the answer.
                guard why.contains("lsof -i :\(port)") || why.lowercased().contains("in use") else { break }
            }
            done(nil, why.isEmpty ? "sl web failed" : String(why.suffix(300)))
        }
    }
}
