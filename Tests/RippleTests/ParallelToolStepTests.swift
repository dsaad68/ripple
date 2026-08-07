import DeepAgents
import Foundation
@testable import ripple
import Testing

/// A round's tools can run at once, so several steps are open in the transcript at the same time
/// and their events interleave. Every tool event carries the `callID` it belongs to; the turn must
/// route on that, because "the last unfinished step" and "the last step with this name" are both
/// wrong once three `read_file` calls are in flight.
@MainActor
struct ParallelToolStepTests {
    private func output(_ step: Step) -> String? {
        guard case .tool(_, _, let output, _, _, _) = step.kind else { return nil }
        return output
    }

    private func steps(_ assistant: Assistant) -> [Step] {
        assistant.blocks.compactMap { if case .step(let step) = $0 { return step } else { return nil } }
    }

    @Test func resultsLandOnTheirOwnStepWhenCallsFinishOutOfOrder() {
        let ids = [UUID(), UUID(), UUID()]
        let assistant = Assistant()
        assistant.consume(.toolStarted(name: "read_file", input: "file_path: a.txt", callID: ids[0]))
        assistant.consume(.toolStarted(name: "read_file", input: "file_path: b.txt", callID: ids[1]))
        assistant.consume(.toolStarted(name: "read_file", input: "file_path: c.txt", callID: ids[2]))
        // Finishing order is the reverse of call order.
        assistant.consume(.toolCompleted(name: "read_file", result: "C", callID: ids[2]))
        assistant.consume(.toolCompleted(name: "read_file", result: "A", callID: ids[0]))
        assistant.consume(.toolCompleted(name: "read_file", result: "B", callID: ids[1]))

        let steps = steps(assistant)
        #expect(steps.map(\.callID) == ids)
        #expect(steps.map(output) == ["A", "B", "C"])
    }

    @Test func streamedProgressReachesTheCallThatProducedIt() {
        let ids = [UUID(), UUID()]
        let assistant = Assistant()
        assistant.consume(.toolStarted(name: "fetch", input: "url: one", callID: ids[0]))
        assistant.consume(.toolStarted(name: "fetch", input: "url: two", callID: ids[1]))
        assistant.consume(.toolProgress(name: "fetch", subagent: nil, delta: "two…", callID: ids[1]))

        #expect(steps(assistant).map(output) == ["", "two…"])
    }

    @Test func aFailureMarksItsOwnStepAndLeavesTheOthersRunning() {
        let ids = [UUID(), UUID()]
        let assistant = Assistant()
        assistant.consume(.toolStarted(name: "grep", input: "pattern: a", callID: ids[0]))
        assistant.consume(.toolStarted(name: "grep", input: "pattern: b", callID: ids[1]))
        assistant.consume(.toolFailed(name: "grep", error: "{\"error\": \"boom\"}", callID: ids[0]))

        let steps = steps(assistant)
        guard case .tool(_, _, _, let firstOK, let firstDone, _) = steps[0].kind,
              case .tool(_, _, _, _, let secondDone, _) = steps[1].kind
        else {
            Issue.record("expected two tool steps")
            return
        }
        #expect(!firstOK)
        #expect(firstDone)
        #expect(!secondDone)
    }

    // MARK: - The parallel indicator

    @Test func stepsOfOneBatchKnowHowManyRanTogether() {
        let batch = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let assistant = Assistant()
        for (index, id) in ids.enumerated() {
            assistant.consume(.toolStarted(name: "read_file", input: "f\(index)", callID: id, batchID: batch))
        }

        // Every card in the batch shows the whole group's size, including the first one - the size
        // is only known once the last start arrives, so the earlier steps have to be revised.
        #expect(steps(assistant).map(\.batchSize) == [3, 3, 3])
    }

    @Test func aCallThatRanAloneCarriesNoBatch() {
        let assistant = Assistant()
        assistant.consume(.toolStarted(name: "write_file", input: "f", callID: UUID()))

        let step = steps(assistant)[0]
        #expect(step.batchID == nil)
        #expect(step.batchSize == 1) // 1 renders as no marker at all
    }

    @Test func twoBatchesInOneRoundAreCountedApart() {
        let first = UUID(), second = UUID()
        let assistant = Assistant()
        assistant.consume(.toolStarted(name: "read_file", input: "a", callID: UUID(), batchID: first))
        assistant.consume(.toolStarted(name: "read_file", input: "b", callID: UUID(), batchID: first))
        assistant.consume(.toolStarted(name: "write_file", input: "c", callID: UUID()))
        assistant.consume(.toolStarted(name: "grep", input: "d", callID: UUID(), batchID: second))

        #expect(steps(assistant).map(\.batchSize) == [2, 2, 1, 1])
    }

    /// The marker has to survive into the drawn card, not just the model - it is the only thing in
    /// the transcript that distinguishes three parallel calls from three sequential ones.
    @Test func theCardDrawsTheParallelMarker() {
        let batch = UUID()
        let assistant = Assistant()
        assistant.consume(.toolStarted(name: "grep", input: "pattern: a", callID: UUID(), batchID: batch))
        assistant.consume(.toolStarted(name: "ls", input: "", callID: UUID(), batchID: batch))
        assistant.consume(.toolStarted(name: "write_file", input: "f", callID: UUID()))

        let agent = RippleDeepAgent.make(textModel: FakeChatModel(answer: "x"))
        let screen = ChatScreen(
            variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: ApprovalGate()
        )
        screen.messages.append(Message(kind: .assistant(assistant)))
        screen.contentHeight = 40
        let drawn = screen.messageLines(width: 72).map(\.text).joined(separator: "\n")

        #expect(drawn.contains("∥2")) // the two batched cards say so…
        #expect(!drawn.contains("∥1")) // …and the one that ran alone says nothing
    }

    @Test func anEventWithoutACallIDStillFillsTheOpenStep() {
        // A step restored from a persisted transcript has no call id, and a host may synthesize
        // events; the older "last unfinished step" rule still applies there.
        let assistant = Assistant()
        assistant.consume(.toolStarted(name: "ls", input: ""))
        assistant.consume(.toolCompleted(name: "ls", result: "a.txt"))

        #expect(steps(assistant).map(output) == ["a.txt"])
    }
}
