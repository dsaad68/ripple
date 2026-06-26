@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
import MLXLMCommon
@testable import ripple
import Testing

/// The shell-command approval card's safety behavior in ``ChatScreen``: it defaults to Reject,
/// offers only two choices (no one-key "always allow"), and the always-allow path is inert for
/// shell - so the loud gate can't be silently disabled with a stray key. A normal tool keeps the
/// usual three-choice, Approve-first card.
@MainActor
struct ShellApprovalCardTests {
    private func makeScreen(gate: ApprovalGate) -> ChatScreen {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        return ChatScreen(variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: gate)
    }

    private func request(tool: String, command: String = "") -> ToolApprovalRequest {
        ToolApprovalRequest(
            id: UUID(), toolName: tool,
            arguments: command.isEmpty ? [:] : ["command": .string(command)],
            description: "test", allowedDecisions: [.approve, .reject]
        )
    }

    /// Drive the gate into a pending state for `request`, returning the in-flight handler task -
    /// resolve the screen to let it finish. The gate suspends inside its handler with `pending`
    /// set, so the screen can be inspected as if a card were on screen.
    private func present(_ request: ToolApprovalRequest, on gate: ApprovalGate) async -> Task<ToolApprovalDecision, Never> {
        let task = Task { await gate.handler(request) }
        for _ in 0 ..< 10000 where gate.pending == nil { await Task.yield() }
        return task
    }

    @Test("The shell card defaults to Reject")
    func shellDefaultsToReject() async {
        let gate = ApprovalGate()
        let screen = makeScreen(gate: gate)
        let task = await present(request(tool: "shell", command: "rm -rf ./build"), on: gate)

        screen.seedApprovalSelection()
        #expect(screen.approvalSelection == 1) // Reject, not Approve (0)
        #expect(screen.approvalChoiceCount == 3) // Approve / Reject / Edit

        screen.resolveApproval(.reject(message: nil))
        _ = await task.value
    }

    @Test("Editing a shell command resolves the call with the edited command, other args preserved")
    func shellEditFlow() async {
        let gate = ApprovalGate()
        let screen = makeScreen(gate: gate)
        let pending = ToolApprovalRequest(
            id: UUID(), toolName: "shell",
            arguments: ["command": .string("rm -rf build"), "timeout": .int(60)],
            description: "test", allowedDecisions: [.approve, .edit, .reject]
        )
        let task = await present(pending, on: gate)

        screen.beginEditingApproval()
        #expect(screen.editingApproval != nil)
        #expect(screen.inputText == "rm -rf build") // command loaded into the input box

        screen.setInput("rm -rf ./build") // the user narrows it to a subfolder
        screen.submitEditedApproval(pending)
        #expect(screen.editingApproval == nil)

        let decision = await task.value
        guard case .edit(let arguments) = decision, case .string(let command)? = arguments["command"] else {
            Issue.record("expected an edit decision carrying the edited command")
            return
        }
        #expect(command == "rm -rf ./build")
        #expect(arguments["timeout"] != nil) // the other arguments are preserved
    }

    @Test("Always-allow is inert for shell, so the gate can't be one-key disabled")
    func shellCannotBeAlwaysAllowed() async {
        let gate = ApprovalGate()
        let screen = makeScreen(gate: gate)
        let task = await present(request(tool: "shell", command: "echo hi"), on: gate)

        screen.alwaysAllow() // the 'A' key / confirm-on-third-choice path
        #expect(gate.pending != nil) // still pending: not approved, not resolved
        #expect(!screen.allowlist.contains("shell")) // and never added to the session allowlist

        screen.resolveApproval(.reject(message: nil))
        _ = await task.value
    }

    @Test("A normal tool keeps the three-choice card, Approve-first and allowlistable")
    func normalToolKeepsThreeChoices() async {
        let gate = ApprovalGate()
        let screen = makeScreen(gate: gate)
        let task = await present(request(tool: "write_file"), on: gate)

        screen.seedApprovalSelection()
        #expect(screen.approvalSelection == 0) // Approve default
        #expect(screen.approvalChoiceCount == 3) // includes "always allow"

        screen.alwaysAllow() // resolves the call and remembers the tool for the session
        #expect(screen.allowlist.contains("write_file"))
        _ = await task.value
    }
}
