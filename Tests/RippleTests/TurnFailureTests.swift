@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import ripple
import Testing

/// A model whose session always throws - the shape of a planner that can't (re)load mid-session
/// (an idle-unloaded model whose weights went missing, an unsupported architecture).
private struct ThrowingChatModel: ChatModel {
    var supportsVision = false
    let error: Error

    func makeSession() -> any ModelTurnSession { ThrowingSession(error: error) }
}

private final class ThrowingSession: ModelTurnSession {
    let error: Error
    init(error: Error) { self.error = error }

    func nextTurn(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [any AgentTool],
        onChunk: @escaping @Sendable (AgentStreamChunk) -> Void
    ) async throws -> AgentMessage {
        throw error
    }
}

/// A generation failure must never end as a silent empty answer: the run's `.failed` event lands on
/// the assistant turn and renders as an error line, whatever had streamed before it.
@MainActor
struct TurnFailureTests {
    @Test func failedEventRecordsTheFailureOnTheTurn() {
        let assistant = Assistant()
        assistant.consume(.token("partial ", isFinal: false))
        assistant.consume(.failed("the model exploded"))
        assistant.complete()

        #expect(assistant.failure == "the model exploded")
        #expect(assistant.answer == "partial ") // whatever streamed stays visible above the error
    }

    @Test func immediateFailureIsNotASilentEmptyTurn() {
        let assistant = Assistant()
        assistant.consume(.failed("boom"))
        assistant.complete()

        #expect(assistant.failure == "boom")
        #expect(assistant.blocks.isEmpty) // nothing streamed - the failure line is all there is
    }

    /// End to end through the real agent loop: a session that throws surfaces as a `.failed` event
    /// carrying the error's readable description, and the assistant turn records it.
    @Test func throwingModelSurfacesItsReasonThroughTheAgent() async {
        let agent = RippleDeepAgent.make(
            textModel: ThrowingChatModel(
                error: RippleModelError.unavailable("mlx-community/some-model", reason: "weights half-fetched")
            ),
            visionModel: nil
        )
        let (ok, events) = await agent.collect([.human("hi")])

        #expect(!ok)
        #expect(events.didFail)
        let assistant = Assistant()
        for event in events { assistant.consume(event) }
        #expect(assistant.failure?.contains("mlx-community/some-model") == true)
        #expect(assistant.failure?.contains("weights half-fetched") == true)
    }

    /// The lazy-load error names the model and carries the loader's reason when there is one - it
    /// is what the transcript's failure line shows, so it must read as a sentence, not an NSError.
    @Test func rippleModelErrorReadsAsASentence() {
        #expect(
            RippleModelError.unavailable("some/model", reason: "snapshot is incomplete").errorDescription
                == "some/model could not be loaded: snapshot is incomplete"
        )
        #expect(
            RippleModelError.unavailable("some/model").errorDescription
                == "some/model could not be loaded"
        )
    }
}

/// A `/model` switch whose rebuild fails must say so in the transcript and keep the current agent -
/// silently staying put reads as a hang.
@MainActor
struct ModelSwitchFailureTests {
    private func makeScreen(build: @escaping ChatScreen.Build) -> ChatScreen {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        let screen = ChatScreen(variant: DeepAgentVariant.all[0], agent: agent, build: build, gate: ApprovalGate())
        screen.quit = true // suppress renders (no live terminal in tests)
        return screen
    }

    @Test func failedSwitchNotesTheFailureAndKeepsTheCurrentVariant() async {
        let screen = makeScreen(build: { _, _ in nil })
        await screen.performSwitch(DeepAgentVariant.all[1])

        #expect(screen.variant.id == DeepAgentVariant.all[0].id)
        #expect(screen.plannerName == ChatScreen.name(DeepAgentVariant.all[0].textModelID))
        #expect(!screen.loading)
        guard case .note(let text)? = screen.messages.last?.kind else {
            Issue.record("expected a transcript note about the failed switch")
            return
        }
        #expect(text.contains("Could not switch to \(DeepAgentVariant.all[1].label)"))
        #expect(text.contains("Still on \(DeepAgentVariant.all[0].label)"))
    }

    @Test func successfulSwitchSwapsTheVariant() async {
        let replacement = RippleDeepAgent.make(textModel: FakeChatModel(answer: "z"))
        let screen = makeScreen(build: { _, _ in replacement })
        await screen.performSwitch(DeepAgentVariant.all[1])

        #expect(screen.variant.id == DeepAgentVariant.all[1].id)
        #expect(screen.plannerName == ChatScreen.name(DeepAgentVariant.all[1].textModelID))
        #expect(screen.messages.isEmpty) // no failure note on the happy path
    }
}
