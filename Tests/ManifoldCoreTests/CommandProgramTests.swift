import Testing
@testable import ManifoldCore

// What a command line runs: its first word, past what only sets it going,
// and through a runner to what it runs.
@Test func theProgramACommandLineRuns() {
    #expect(CommandProgram.program(in: "git log --oneline") == "git")
    #expect(CommandProgram.program(in: "/usr/bin/vim foo.swift") == "vim")
    #expect(CommandProgram.program(in: "sudo -E docker compose up") == "docker")
    #expect(CommandProgram.program(in: "FOO=1 BAR=2 node server.js") == "node")
    #expect(CommandProgram.program(in: "env -i time nice -n 5 cargo build") == "cargo")
    #expect(CommandProgram.program(in: "npx vite --port 3000") == "vite")
    #expect(CommandProgram.program(in: "uv run pytest -x") == "pytest")
    #expect(CommandProgram.program(in: "uv tool run ruff check") == "ruff")
    #expect(CommandProgram.program(in: "pnpm dlx turbo build") == "turbo")
    #expect(CommandProgram.program(in: "npm run dev") == "npm")
    #expect(CommandProgram.program(in: "kubectl get pods | grep api") == "kubectl")
    #expect(CommandProgram.program(in: "  ") == nil)
}
