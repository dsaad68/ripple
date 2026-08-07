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

    @Test func anEventWithoutACallIDStillFillsTheOpenStep() {
        // A step restored from a persisted transcript has no call id, and a host may synthesize
        // events; the older "last unfinished step" rule still applies there.
        let assistant = Assistant()
        assistant.consume(.toolStarted(name: "ls", input: ""))
        assistant.consume(.toolCompleted(name: "ls", result: "a.txt"))

        #expect(steps(assistant).map(output) == ["a.txt"])
    }
}
