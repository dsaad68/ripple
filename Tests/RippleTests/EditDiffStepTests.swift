import DeepAgents
@testable import ripple
import Testing

/// `edit_file` attaches a ``FileDiff`` to its `.toolCompleted` event; the chat turn must stash it on
/// the matching ``Step`` so the transcript can render a diff card instead of the plain text result.
@MainActor
struct EditDiffStepTests {
    @Test func toolCompletedStoresDiffOnStep() {
        let assistant = Assistant()
        assistant.consume(.toolStarted(name: "edit_file", input: "file_path: a.txt"))
        let diff = FileDiff.compute(path: "a.txt", before: "x\ny\nz", after: "x\nY\nz")
        assistant.consume(.toolCompleted(name: "edit_file", result: "Edited \"a.txt\".", editDiff: diff))

        guard case .step(let step) = assistant.blocks.last else {
            Issue.record("expected a tool step")
            return
        }
        #expect(step.diff?.path == "a.txt")
        #expect(step.diff?.added == 1)
        #expect(step.diff?.removed == 1)
    }

    @Test func toolWithoutDiffLeavesStepDiffNil() {
        let assistant = Assistant()
        assistant.consume(.toolStarted(name: "ls", input: ""))
        assistant.consume(.toolCompleted(name: "ls", result: "a.txt"))

        guard case .step(let step) = assistant.blocks.last else {
            Issue.record("expected a tool step")
            return
        }
        #expect(step.diff == nil)
    }
}
