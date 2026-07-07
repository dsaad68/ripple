@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
import MLXLMCommon
@testable import ripple
import Testing

/// `BangCommand` is the model behind a `!cmd` / `!!cmd` line the user runs directly: it streams
/// output while running, then `complete` replaces that with the authoritative combined result
/// (mirroring the shell tool's formatting), and `fail` / `stop` are the unavailable / cancelled
/// terminals. These cover that lifecycle without shelling out.
@MainActor
struct BangCommandTests {
    private func result(_ stdout: String, _ stderr: String = "", status: Int32 = 0, timedOut: Bool = false) -> ProcessRunner.Result {
        ProcessRunner.Result(stdout: stdout, stderr: stderr, status: status, timedOut: timedOut)
    }

    @Test func startsRunningWithItsTargetAndCommand() {
        let bang = BangCommand(command: "ls -la", target: .local)
        #expect(bang.command == "ls -la")
        #expect(bang.target == .local)
        #expect(bang.running)
        #expect(bang.output.isEmpty)
        #expect(bang.status == nil)
        #expect(bang.seconds == nil)
    }

    @Test func completeCombinesStdoutAndStderrAndStops() {
        let bang = BangCommand(command: "build", target: .container)
        bang.complete(result("out", "warn"))
        #expect(bang.output == "out\nwarn")
        #expect(bang.status == 0)
        #expect(!bang.running)
        #expect(!bang.failed)
        #expect(bang.seconds != nil)
    }

    @Test func completeNotesANonZeroExit() {
        let bang = BangCommand(command: "false", target: .local)
        bang.complete(result("", status: 1))
        #expect(bang.output == "[Exited with status 1.]")
        #expect(bang.status == 1)
    }

    @Test func completeNotesATimeout() {
        let bang = BangCommand(command: "sleep 999", target: .local)
        bang.complete(result("partial", status: 15, timedOut: true))
        #expect(bang.output == "partial\n[Command timed out and was killed.]")
    }

    @Test func cleanRunWithNoOutputReadsAsNoOutput() {
        let bang = BangCommand(command: "true", target: .container)
        bang.complete(result(""))
        #expect(bang.output == "(no output)")
    }

    @Test func streamedChunksAccumulateWhileRunningThenAreReplaced() {
        let bang = BangCommand(command: "echo hi", target: .local)
        bang.stream("partial ")
        bang.stream("stream")
        #expect(bang.output == "partial stream")
        bang.complete(result("final output", status: 0)) // the authoritative result replaces the stream
        #expect(bang.output == "final output")
        bang.stream(" late") // a chunk arriving after completion is ignored
        #expect(bang.output == "final output")
    }

    @Test func failShowsTheReasonAndStops() {
        let bang = BangCommand(command: "uv --version", target: .container)
        bang.fail("the container sandbox is unavailable")
        #expect(bang.failed)
        #expect(!bang.running)
        #expect(bang.output == "the container sandbox is unavailable")
    }

    @Test func stopMarksItInterruptedAndIsTerminal() {
        let bang = BangCommand(command: "sleep 999", target: .local)
        bang.stop()
        #expect(bang.interrupted)
        #expect(!bang.running)
        bang.complete(result("late output")) // a background completion after a stop is ignored
        #expect(!bang.failed)
        #expect(bang.output.isEmpty)
    }
}

/// Typing a bang prefix in the input box puts the screen in bang mode, which restyles the box: a
/// single `!` targets the container (blue), `!!` the local shell (green), and anything else is a
/// normal message (the default dim border).
@MainActor
struct ChatScreenBangModeTests {
    private func makeScreen() -> ChatScreen {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        return ChatScreen(variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: ApprovalGate())
    }

    @Test func bangPrefixSelectsTheTargetAndAccent() {
        let screen = makeScreen()
        #expect(screen.bangMode == nil) // empty: a normal message
        #expect(screen.inputAccent == 238)

        screen.setInput("!ls")
        #expect(screen.bangMode == .container) // single bang -> container
        #expect(screen.inputAccent == 75)

        screen.setInput("!!ls")
        #expect(screen.bangMode == .local) // double bang -> local shell
        #expect(screen.inputAccent == 114)

        screen.setInput("ls -la")
        #expect(screen.bangMode == nil) // no bang -> normal message
        #expect(screen.inputAccent == 238)
    }
}
