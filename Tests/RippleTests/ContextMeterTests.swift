import DeepAgents
import DeepAgentsMLX
import Foundation
@testable import ripple
import Testing

/// The status bar's context meter - the `○ 0%` between the git branch and the model name. It reports
/// what the *next* request will cost, measured from the agent, and must agree with the automatic
/// compaction that fires off the same number: a meter that only tallies the tokens it watched stream
/// past omits the tool schemas (paid on every request) and every tool result, so it reads far below
/// the truth and compaction looks like it triggers at a quarter of the window.
@MainActor
struct ContextMeterTests {
    private func makeScreen(_ model: FakeChatModel = FakeChatModel(answer: "ok")) -> ChatScreen {
        let agent = RippleDeepAgent.make(
            textModel: model,
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        return ChatScreen(variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: ApprovalGate())
    }

    @Test("An empty session already costs its system prompt and tool schemas")
    func emptySessionIsNotZero() async {
        let screen = makeScreen()
        #expect(screen.sessionTokens == 0) // before any measurement
        let measured = await screen.agent.contextTokens(threadId: screen.threadId)
        #expect(measured > 0, "the prompt overhead is never free")
        // The overhead is the fixed cost of the rendered tools + system prompt, so it is substantial.
        #expect(measured > 200)

        screen.refreshContextMeter()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(screen.sessionTokens == measured)
    }

    // A turn cannot be driven here: `runTurn` ends in `MLX.Memory.clearCache()`, which aborts the
    // whole test process under plain `swift test` (no metallib beside the binary). That the measure
    // tracks a growing thread is covered where no MLX is linked - see DeepAgents'
    // `ReactAgentContextTokensTests`.

    @Test("The meter is measured against the agent, so it survives a rewritten history")
    func measurementFollowsTheThread() async {
        let screen = makeScreen()
        screen.sessionTokens = 999_999 // as if a stale tally had run away
        screen.refreshContextMeter()
        try? await Task.sleep(for: .milliseconds(50))
        let truth = await screen.agent.contextTokens(threadId: screen.threadId)
        #expect(screen.sessionTokens == truth)
        #expect(screen.sessionTokens < 999_999)
    }

    @Test("A thread with no stored history still reports the prompt overhead")
    func unknownThreadReportsOverhead() async {
        let screen = makeScreen()
        let fresh = await screen.agent.contextTokens(threadId: UUID().uuidString)
        let current = await screen.agent.contextTokens(threadId: screen.threadId)
        #expect(fresh > 0)
        #expect(fresh == current) // both empty: the same fixed overhead, no history on either
    }
}
