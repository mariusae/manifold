import Foundation
import Testing
@testable import ManifoldCore
@testable import manifoldd

// Antigravity (`agy`) omits `PreToolUse`, so `manifoldd` watches its active
// turn's `transcript.jsonl` and updates `Block.agentDoing` as tool calls land.
extension ProcessLifecycle {
    @Test func antigravityUpdatesAgentDoingFromLiveTranscript() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agy-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dataBefore = ProcessInfo.processInfo.environment["MANIFOLD_DIR"]
        setenv("MANIFOLD_DIR", base.appendingPathComponent("data").path, 1)
        defer { if let dataBefore { setenv("MANIFOLD_DIR", dataBefore, 1) } else { unsetenv("MANIFOLD_DIR") } }

        let server = try Server()
        let blockID = BlockID(host: server.host)
        let transcript = base.appendingPathComponent("transcript.jsonl")
        func line(_ o: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n"
        }
        func appendLine(_ o: [String: Any]) throws {
            let data = Data(line(o).utf8)
            if FileManager.default.fileExists(atPath: transcript.path) {
                let h = try FileHandle(forWritingTo: transcript)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: data)
            } else {
                try data.write(to: transcript)
            }
        }

        // Create an Antigravity agent block and start a turn before the transcript exists.
        server.queue.sync {
            _ = server.ensure(blockID, kind: .agent, title: "Antigravity", cwd: base.path)
            server.agentEvent(blockID, .prompt(agent: "agy", text: "fix the parser", transcript: transcript.path))
        }
        #expect(server.queue.sync { server.node.block(blockID)?.agentDoing } == nil)
        #expect(server.queue.sync { server.node.block(blockID)?.statusState } == .working)

        // Transcript appears with the user prompt and first tool call.
        try appendLine(["step_index": 0, "type": "USER_INPUT", "source": "USER_EXPLICIT",
                        "content": "<USER_REQUEST>\nfix the parser\n</USER_REQUEST>"])
        try appendLine(["step_index": 1, "type": "PLANNER_RESPONSE", "source": "MODEL",
                        "tool_calls": [["name": "read_file", "args": ["Path": "\"/repo/Sources/Parser.swift\""]]]])
        wait(3, on: server.queue) {
            server.queue.sync { server.node.block(blockID)?.agentDoing == "Reading Parser.swift" }
        }
        #expect(server.queue.sync { server.node.block(blockID)?.agentDoing } == "Reading Parser.swift")

        // Next model step calls run_command with toolSummary: status updates live.
        try appendLine(["step_index": 2, "type": "PLANNER_RESPONSE", "source": "MODEL",
                        "tool_calls": [["name": "run_command", "args": ["CommandLine": "\"swift test\"", "toolSummary": "\"Unit test execution\""]]]])
        wait(3, on: server.queue) {
            server.queue.sync { server.node.block(blockID)?.agentDoing == "Unit test execution" }
        }
        #expect(server.queue.sync { server.node.block(blockID)?.agentDoing } == "Unit test execution")

        // Turn finishes: final words read from transcript, agentDoing clears, and later writes don't reopen it.
        try appendLine(["step_index": 3, "type": "PLANNER_RESPONSE", "source": "MODEL",
                        "content": "Fixed the parser."])
        server.queue.sync {
            server.agentEvent(blockID, .finished(agent: "agy", message: nil, transcript: transcript.path))
        }
        #expect(server.queue.sync { server.node.block(blockID)?.statusState } == .done)
        #expect(server.queue.sync { server.node.block(blockID)?.agentDoing } == nil)

        try appendLine(["step_index": 4, "type": "PLANNER_RESPONSE", "source": "MODEL",
                        "tool_calls": [["name": "edit_file", "args": ["Path": "\"/repo/Sources/Late.swift\""]]]])
        wait(0.3, on: server.queue) { false }
        #expect(server.queue.sync { server.node.block(blockID)?.statusState } == .done)
        #expect(server.queue.sync { server.node.block(blockID)?.agentDoing } == nil)
    }

    @Test func antigravityBackgroundWakeupReopensTurnInsteadOfRepeatingPrompt() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agy-wakeup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dataBefore = ProcessInfo.processInfo.environment["MANIFOLD_DIR"]
        setenv("MANIFOLD_DIR", base.appendingPathComponent("data").path, 1)
        defer { if let dataBefore { setenv("MANIFOLD_DIR", dataBefore, 1) } else { unsetenv("MANIFOLD_DIR") } }

        let server = try Server()
        let blockID = BlockID(host: server.host)
        let transcript = base.appendingPathComponent("transcript.jsonl")
        func line(_ o: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n"
        }
        func appendLine(_ o: [String: Any]) throws {
            let data = Data(line(o).utf8)
            if FileManager.default.fileExists(atPath: transcript.path) {
                let h = try FileHandle(forWritingTo: transcript)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: data)
            } else {
                try data.write(to: transcript)
            }
        }

        // First prompt and initial reply before a background task finishes.
        try appendLine(["step_index": 10, "type": "USER_INPUT", "source": "USER_EXPLICIT",
                        "content": "<USER_REQUEST>\nrun the tests\n</USER_REQUEST>"])
        server.queue.sync {
            _ = server.ensure(blockID, kind: .agent, title: "Antigravity", cwd: base.path)
            server.agentEvent(blockID, .prompt(agent: "agy", text: "run the tests", transcript: transcript.path))
        }
        try appendLine(["step_index": 11, "type": "PLANNER_RESPONSE", "source": "MODEL",
                        "content": "Running the tests now."])
        server.queue.sync {
            server.agentEvent(blockID, .finished(agent: "agy", message: nil, transcript: transcript.path))
        }
        #expect(server.queue.sync { server.node.block(blockID)?.terminal?.turns?.count } == 1)
        #expect(server.queue.sync { server.node.block(blockID)?.terminal?.turns?.last?.isRunning } == false)

        // Background task finishes: SYSTEM_MESSAGE arrives and PreInvocation fires
        // again with the same lastUserInput and NO new USER_INPUT in transcript.jsonl.
        try appendLine(["step_index": 12, "type": "SYSTEM_MESSAGE", "source": "SYSTEM",
                        "content": "Task finished."])
        server.queue.sync {
            server.agentEvent(blockID, .prompt(agent: "agy", text: "run the tests", transcript: transcript.path))
        }
        #expect(server.queue.sync { server.node.block(blockID)?.terminal?.turns?.count } == 1)
        #expect(server.queue.sync { server.node.block(blockID)?.terminal?.turns?.last?.isRunning } == true)

        // Live doing resumes on the reopened turn.
        try appendLine(["step_index": 13, "type": "PLANNER_RESPONSE", "source": "MODEL",
                        "tool_calls": [["name": "read_file", "args": ["Path": "\"/repo/Sources/Fix.swift\""]]]])
        wait(3, on: server.queue) {
            server.queue.sync { server.node.block(blockID)?.agentDoing == "Reading Fix.swift" }
        }
        #expect(server.queue.sync { server.node.block(blockID)?.agentDoing } == "Reading Fix.swift")

        // Second Stop closes the reopened turn.
        try appendLine(["step_index": 14, "type": "PLANNER_RESPONSE", "source": "MODEL",
                        "content": "All tests passed."])
        server.queue.sync {
            server.agentEvent(blockID, .finished(agent: "agy", message: nil, transcript: transcript.path))
        }
        #expect(server.queue.sync { server.node.block(blockID)?.terminal?.turns?.count } == 1)

        // If the user genuinely sends the exact same prompt again, a new USER_INPUT
        // appears at a new step_index and starts a second turn.
        try appendLine(["step_index": 15, "type": "USER_INPUT", "source": "USER_EXPLICIT",
                        "content": "<USER_REQUEST>\nrun the tests\n</USER_REQUEST>"])
        server.queue.sync {
            server.agentEvent(blockID, .prompt(agent: "agy", text: "run the tests", transcript: transcript.path))
        }
        #expect(server.queue.sync { server.node.block(blockID)?.terminal?.turns?.count } == 2)
    }
}
