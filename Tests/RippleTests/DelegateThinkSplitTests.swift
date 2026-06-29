@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
@testable import ripple
import Testing

/// A delegate (`task`) step splits its subagent's streamed output into `<think>…</think>` reasoning
/// and the answer, so each collapses independently in the transcript. `ChatScreen.splitThink` is
/// that pure seam.
@MainActor
struct DelegateThinkSplitTests {
    @Test func separatesReasoningFromAnswer() {
        let (reasoning, answer) = ChatScreen.splitThink("<think>weighing options</think>\n\nthe answer")
        #expect(reasoning == "weighing options")
        #expect(answer == "the answer")
    }

    @Test func streamingThinkHasNoAnswerYet() {
        // An unclosed <think> (still thinking) is all reasoning, no answer.
        let (reasoning, answer) = ChatScreen.splitThink("<think>still reasoning, no close tag")
        #expect(reasoning == "still reasoning, no close tag")
        #expect(answer.isEmpty)
    }

    @Test func noThinkTagIsAllAnswer() {
        let (reasoning, answer) = ChatScreen.splitThink("a plain answer with no reasoning")
        #expect(reasoning.isEmpty)
        #expect(answer == "a plain answer with no reasoning")
    }

    @Test func answerWrapsTheThinkBlockOnBothSides() {
        let (reasoning, answer) = ChatScreen.splitThink("before <think>mid</think> after")
        #expect(reasoning == "mid")
        #expect(answer == "before  after")
    }
}
