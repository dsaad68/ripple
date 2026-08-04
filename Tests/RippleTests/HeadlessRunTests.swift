import ArgumentParser
@testable import DeepAgents
import Foundation
@testable import ripple
import Testing

/// The non-interactive (`ripple -p`) path: argument parsing (incl. the bare-flag normalization),
/// the permission-mode -> decision mapping, flag -> policy folding, the output renderers
/// (text / json / stream-json), and the exit-code mapping. All pure - no model, no agent run.
struct HeadlessRunTests {
    // MARK: - normalizeOptionalValueFlags

    @Test func normalizesBareSandbox() {
        #expect(normalizeOptionalValueFlags(["--sandbox"]) == ["--sandbox", "failover"])
        #expect(normalizeOptionalValueFlags(["--sandbox", "off"]) == ["--sandbox", "off"])
        #expect(normalizeOptionalValueFlags(["--sandbox", "container-only"]) == ["--sandbox", "container-only"])
        // A following flag isn't a mode value -> the bare form expands to failover.
        #expect(normalizeOptionalValueFlags(["--sandbox", "--model", "x"]) == ["--sandbox", "failover", "--model", "x"])
    }

    @Test func normalizesBareResume() {
        let pick = CommonRunOptions.resumePickToken
        #expect(normalizeOptionalValueFlags(["--resume"]) == ["--resume", pick])
        #expect(normalizeOptionalValueFlags(["--resume", "abc"]) == ["--resume", "abc"])
        #expect(normalizeOptionalValueFlags(["--resume", "--model", "x"]) == ["--resume", pick, "--model", "x"])
        #expect(normalizeOptionalValueFlags(["-p", "hi"]) == ["-p", "hi"]) // untouched
    }

    // MARK: - argument parsing

    @Test func parsesHeadlessFlags() throws {
        let args = normalizeOptionalValueFlags([
            "-p", "summarize", "--output-format", "stream-json", "--permission-mode", "accept-all",
            "--allow-tool", "shell", "--allow-tool", "write_file", "--deny-tool", "edit_file",
            "--disable-middleware", "web", "--sandbox", "container-only", "--sandbox-image", "img:1",
            "--model", "my-model", "--log", "/tmp/log", "--yes"
        ])
        let cmd = try Ripple.parse(args)
        #expect(cmd.prompt == "summarize")
        #expect(cmd.outputFormat == .streamJSON)
        #expect(cmd.permissionMode == .acceptAll)
        #expect(cmd.allowTool == ["shell", "write_file"])
        #expect(cmd.denyTool == ["edit_file"])
        #expect(cmd.disableMiddleware == ["web"])
        #expect(cmd.sandboxImage == "img:1")
        #expect(cmd.common.sandbox == .containerOnly)
        #expect(cmd.common.model == "my-model")
        #expect(cmd.common.log == "/tmp/log")
        #expect(cmd.common.yes == true)
    }

    @Test func defaultsAndResumeForms() throws {
        let plain = try Ripple.parse([])
        #expect(plain.prompt == nil)
        #expect(plain.outputFormat == nil) // headless-only; nil means "not set"
        #expect(plain.permissionMode == nil) // nil so the interactive path can detect explicit use
        #expect(plain.common.sandbox == nil)

        // bare --resume -> pick; --resume <id> -> id.
        let pick = try Ripple.parse(normalizeOptionalValueFlags(["--resume"]))
        #expect(isPick(pick.common.resumeRequest))
        let byID = try Ripple.parse(normalizeOptionalValueFlags(["--resume", "sess-1"]))
        #expect(resumeID(byID.common.resumeRequest) == "sess-1")
        #expect(plain.common.resumeRequest == nil)
    }

    @Test func detectsHeadlessOnlyFlags() throws {
        // Headless-only flags are detected so the interactive path can reject them instead of ignoring.
        #expect(try Ripple.parse([]).headlessOnlyFlagsInUse().isEmpty)
        #expect(try Ripple.parse(["--output-format", "json"]).headlessOnlyFlagsInUse() == ["--output-format"])
        #expect(try Ripple.parse(["--permission-mode", "plan"]).headlessOnlyFlagsInUse() == ["--permission-mode"])
        #expect(try Ripple.parse(["--allow-tool", "shell"]).headlessOnlyFlagsInUse() == ["--allow-tool"])
        #expect(try Ripple.parse(["--sandbox-image", "img"]).headlessOnlyFlagsInUse() == ["--sandbox-image"])
        // Shared run flags (model/log/sandbox/yes/resume) are not headless-only.
        let shared = try Ripple.parse(normalizeOptionalValueFlags(["--model", "m", "--sandbox", "--resume", "--yes"]))
        #expect(shared.headlessOnlyFlagsInUse().isEmpty)
    }

    @Test func rejectsUnknownEnumValues() {
        #expect(throws: (any Error).self) { try Ripple.parse(["-p", "x", "--output-format", "bogus"]) }
        #expect(throws: (any Error).self) { try Ripple.parse(["-p", "x", "--permission-mode", "bogus"]) }
        #expect(throws: (any Error).self) { try Ripple.parse(["-p", "x", "--sandbox", "bogus"]) }
    }

    // MARK: - PermissionMode.decision

    @Test func permissionModeDecisions() {
        // ask: never auto-resolves (would prompt -> nil).
        #expect(PermissionMode.ask.decision(for: "read_file") == nil)
        #expect(PermissionMode.ask.decision(for: "write_file") == nil)
        // auto-reads: reads approved, writes prompt.
        #expect(isApprove(PermissionMode.autoReads.decision(for: "read_file")))
        #expect(isApprove(PermissionMode.autoReads.decision(for: "ls")))
        #expect(PermissionMode.autoReads.decision(for: "write_file") == nil)
        // accept-all: everything approved.
        #expect(isApprove(PermissionMode.acceptAll.decision(for: "read_file")))
        #expect(isApprove(PermissionMode.acceptAll.decision(for: "shell")))
        // plan: reads approved, writes rejected (dry run).
        #expect(isApprove(PermissionMode.plan.decision(for: "read_file")))
        #expect(isReject(PermissionMode.plan.decision(for: "write_file")))
    }

    // MARK: - flag -> policy folding

    @Test func overlayFoldsFlagsIntoPolicy() {
        var options = HeadlessOptions()
        options.allowTools = ["shell"]
        options.denyTools = ["write_file"]
        options.disableMiddleware = ["web"]
        options.sandbox = .containerOnly
        options.sandboxImage = "img:2"
        let policy = options.overlay(onto: AgentToolPolicy())
        #expect(policy.approvals["shell"] == .approve)
        #expect(policy.approvals["write_file"] == .deny)
        #expect(policy.disabledMiddleware.contains("web"))
        #expect(policy.sandbox == .containerOnly)
        #expect(policy.sandboxImage == "img:2")
    }

    @Test func overlayLeavesSandboxUntouchedWhenUnset() {
        let base = AgentToolPolicy(sandbox: .failover, sandboxImage: "base")
        let policy = HeadlessOptions().overlay(onto: base) // no sandbox flag
        #expect(policy.sandbox == .failover)
        #expect(policy.sandboxImage == "base")
    }

    // MARK: - exit codes

    @Test func exitCodeMapping() {
        #expect(HeadlessRun.exitCode(ok: true, blocked: false) == 0)
        #expect(HeadlessRun.exitCode(ok: false, blocked: false) == 1)
        #expect(HeadlessRun.exitCode(ok: false, blocked: true) == 1) // failure beats block
        #expect(HeadlessRun.exitCode(ok: true, blocked: true) == 3)
    }

    // MARK: - renderers

    @Test func textRendererPrintsAnswerToStdoutAndToolsToStderr() {
        let capture = Capture()
        let renderer = OutputFormat.text.makeRenderer(sink: capture.sink)
        renderer.handle(.toolStarted(name: "shell", input: "ls -a"))
        renderer.handle(.token("partial", isFinal: false))
        renderer.handle(.toolFailed(name: "shell", error: "boom"))
        renderer.finish(result(answer: "the answer", tools: ["shell"], rounds: 2))
        #expect(capture.out == "the answer\n") // final answer only, newline-terminated
        #expect(capture.err.contains("· shell: ls -a"))
        #expect(capture.err.contains("· shell failed: boom"))
    }

    @Test func jsonRendererEmitsResultObject() throws {
        let capture = Capture()
        let renderer = OutputFormat.json.makeRenderer(sink: capture.sink)
        renderer.handle(.token("ignored", isFinal: false)) // json ignores live events
        renderer.finish(result(answer: "42", tools: ["calculator"], rounds: 1))
        let object = try JSONSerialization.jsonObject(with: Data(capture.out.utf8)) as? [String: Any]
        #expect(object?["type"] as? String == "result")
        #expect(object?["subtype"] as? String == "success")
        #expect(object?["result"] as? String == "42")
        #expect(object?["is_error"] as? Bool == false)
        #expect(object?["permission_blocked"] as? Bool == false)
        #expect(object?["num_turns"] as? Int == 1)
        #expect((object?["tools_used"] as? [String]) == ["calculator"])
    }

    @Test func jsonRendererMarksErrorRuns() throws {
        let capture = Capture()
        let renderer = OutputFormat.json.makeRenderer(sink: capture.sink)
        renderer.finish(HeadlessResult(
            answer: "", ok: false, blocked: true, toolsUsed: [], rounds: 0, model: "m", error: "kaboom"
        ))
        let object = try JSONSerialization.jsonObject(with: Data(capture.out.utf8)) as? [String: Any]
        #expect(object?["subtype"] as? String == "error")
        #expect(object?["is_error"] as? Bool == true)
        #expect(object?["permission_blocked"] as? Bool == true)
        #expect(object?["error"] as? String == "kaboom")
    }

    @Test func streamJSONEmitsOneLinePerEventThenResult() throws {
        let capture = Capture()
        let renderer = OutputFormat.streamJSON.makeRenderer(sink: capture.sink)
        renderer.handle(.token("hi", isFinal: false))
        renderer.handle(.toolStarted(name: "shell", input: "ls"))
        renderer.handle(.roundCompleted(hadToolCalls: true))
        renderer.finish(result(answer: "done", tools: ["shell"], rounds: 1))

        let lines = capture.out.split(separator: "\n").map(String.init)
        #expect(lines.count == 4) // 3 events + 1 result
        let parsed = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(parsed[0]?["type"] as? String == "token")
        #expect(parsed[0]?["text"] as? String == "hi")
        #expect(parsed[1]?["type"] as? String == "tool_started")
        #expect(parsed[1]?["name"] as? String == "shell")
        #expect(parsed[2]?["type"] as? String == "round_completed")
        #expect(parsed[2]?["hadToolCalls"] as? Bool == true)
        #expect(parsed[3]?["type"] as? String == "result")
    }

    @Test func eventLineEncodesFailedAndTodos() throws {
        let failed = try decode(jsonLine(#require(EventLine(.failed("nope"))), pretty: false))
        #expect(failed["type"] as? String == "failed")
        #expect(failed["error"] as? String == "nope")

        let todos = TodoItem(content: "step", status: .inProgress)
        let line = try decode(jsonLine(#require(EventLine(.todosUpdated([todos]))), pretty: false))
        #expect(line["type"] as? String == "todos")
        let encoded = line["todos"] as? [[String: Any]]
        #expect(encoded?.first?["content"] as? String == "step")
        #expect(encoded?.first?["status"] as? String == "in_progress")
    }

    // MARK: - drive (real agent run, scripted model, no MLX)

    @MainActor @Test func driveRunsAgentAndRendersResult() async {
        // A scripted planner that answers in one round (no tools) - exercises the real ReactAgent run
        // through `drive` and the json renderer, end to end, without any MLX/model loading.
        let agent = RippleDeepAgent.make(textModel: FakeChatModel(answer: "pong"))
        let capture = Capture()
        let result = await HeadlessRun.drive(
            agent: agent, prompt: "ping", model: "fake",
            renderer: OutputFormat.json.makeRenderer(sink: capture.sink), blocked: HeadlessRun.BlockFlag()
        )
        #expect(result.answer == "pong")
        #expect(result.ok)
        #expect(!result.blocked)
        let object = try? JSONSerialization.jsonObject(with: Data(capture.out.utf8)) as? [String: Any]
        #expect(object?["result"] as? String == "pong")
        #expect(object?["subtype"] as? String == "success")
    }

    @MainActor @Test func driveCapturesToolCallsAndFinalAnswer() async {
        // Round 1 calls `echo`, round 2 answers - verifies tool accounting and that the final answer is
        // the last (no-tool) round's text, not the interim text.
        let call = AgentToolCall(name: "echo", arguments: ["text": .string("hi")])
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "all done", toolCalls: [call]),
            approvalHandler: { _ in .approve }
        )
        let capture = Capture()
        let result = await HeadlessRun.drive(
            agent: agent, prompt: "go", model: "fake",
            renderer: OutputFormat.text.makeRenderer(sink: capture.sink), blocked: HeadlessRun.BlockFlag()
        )
        #expect(result.answer == "all done")
        #expect(result.toolsUsed.contains("echo"))
        #expect(capture.out == "all done\n")
    }

    // MARK: - helpers

    private func result(answer: String, tools: [String], rounds: Int) -> HeadlessResult {
        HeadlessResult(
            answer: answer, ok: true, blocked: false, toolsUsed: tools, rounds: rounds, model: "m", error: nil
        )
    }

    private func decode(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func isApprove(_ decision: ToolApprovalDecision?) -> Bool {
        if case .approve = decision { return true }
        return false
    }

    private func isReject(_ decision: ToolApprovalDecision?) -> Bool {
        if case .reject = decision { return true }
        return false
    }

    private func isPick(_ request: ResumeRequest?) -> Bool {
        if case .pick = request { return true }
        return false
    }

    private func resumeID(_ request: ResumeRequest?) -> String? {
        if case .id(let id) = request { return id }
        return nil
    }
}

/// Collects a renderer's stdout/stderr writes for assertions.
private final class Capture {
    private(set) var out = ""
    private(set) var err = ""
    var sink: HeadlessSink {
        HeadlessSink(out: { [weak self] in self?.out += $0 }, err: { [weak self] in self?.err += $0 })
    }
}
