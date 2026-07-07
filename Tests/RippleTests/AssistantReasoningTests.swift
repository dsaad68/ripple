@testable import DeepAgents
@testable import ripple
import Testing

/// The chat turn keeps reasoning, tool calls, and the answer as an ordered timeline. Reasoning now
/// arrives on its own `.reasoningToken` channel (not inline `<think>` in the answer tokens), so these
/// drive that channel directly and assert the blocks land in the order they streamed.
@MainActor
struct AssistantReasoningTests {
    /// A coarse tag per block, for asserting order.
    private func shape(_ assistant: Assistant) -> [String] {
        assistant.blocks.map { block in
            switch block {
            case .reasoning: return "reason"
            case .answer: return "answer"
            case .step: return "tool"
            }
        }
    }

    @Test func interleavesReasoningBetweenToolCallsInOrder() {
        let assistant = Assistant()
        // Round 1: reasoning on its channel, then a tool call.
        assistant.consume(.reasoningToken("first I plan"))
        assistant.consume(.toolStarted(name: "ls", input: "path: ."))
        assistant.consume(.toolCompleted(name: "ls", result: "a.txt"))
        // Round 2: reasoning again, then the answer.
        assistant.consume(.reasoningToken("now I answer"))
        assistant.consume(.token("Here is the file.", isFinal: false))
        assistant.complete()

        #expect(shape(assistant) == ["reason", "tool", "reason", "answer"])
        #expect(assistant.answer == "Here is the file.")
    }

    @Test func reasoningClosesWhenTheAnswerBegins() {
        let assistant = Assistant()
        assistant.consume(.reasoningToken("thinking"))
        assistant.consume(.token("answer", isFinal: false))

        guard case .reasoning(let reasoning) = assistant.blocks.first else {
            Issue.record("expected a leading reasoning block")
            return
        }
        #expect(reasoning.text == "thinking")
        #expect(!reasoning.streaming) // the answer token ended the reasoning block
        #expect(reasoning.seconds != nil)
    }

    @Test func toolStartedClosesOpenReasoning() {
        let assistant = Assistant()
        assistant.consume(.reasoningToken("thinking hard"))
        assistant.consume(.toolStarted(name: "ls", input: ""))

        guard case .reasoning(let reasoning) = assistant.blocks.first else {
            Issue.record("expected a leading reasoning block")
            return
        }
        #expect(!reasoning.streaming)
    }

    @Test func unclosedReasoningStaysStreaming() {
        let assistant = Assistant()
        assistant.consume(.reasoningToken("still going")) // no answer yet

        guard case .reasoning(let reasoning) = assistant.blocks.first else {
            Issue.record("expected a reasoning block")
            return
        }
        #expect(reasoning.streaming)
        #expect(reasoning.text == "still going")
        #expect(assistant.answer.isEmpty)
    }

    @Test func answerOnlyTurnHasNoReasoning() {
        let assistant = Assistant()
        assistant.consume(.token("Hello ", isFinal: false))
        assistant.consume(.token("world.", isFinal: false))
        assistant.complete()

        #expect(assistant.answer == "Hello world.")
        #expect(shape(assistant) == ["answer"])
    }

    @Test func emptyChunksOpenNoBlocks() {
        let assistant = Assistant()
        assistant.consume(.reasoningToken(""))
        assistant.consume(.token("", isFinal: false))
        #expect(assistant.blocks.isEmpty)
    }

    /// The plan is pinned in its own panel, so a `.todosUpdated` event closes any open text run but
    /// never appends a transcript block - the plan no longer stacks up in the scrollback.
    @Test func todosUpdatedAddsNoTranscriptBlock() {
        let assistant = Assistant()
        assistant.consume(.toolStarted(name: "ls", input: "path: ."))
        assistant.consume(.toolCompleted(name: "ls", result: "a.txt"))
        assistant.consume(.todosUpdated([
            TodoItem(content: "step one", status: .inProgress),
            TodoItem(content: "step two", status: .pending)
        ]))
        assistant.consume(.todosUpdated([
            TodoItem(content: "step one", status: .completed),
            TodoItem(content: "step two", status: .inProgress)
        ]))
        assistant.complete()
        #expect(shape(assistant) == ["tool"]) // two plan updates, still just the one tool block
    }
}
