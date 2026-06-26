@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import ripple
import Testing

/// DeepAgent's vision handoff: the planner captures a screenshot it can't view, and the `task` tool
/// forwards that image down into the vision subagent (then clears it). Also covers the structural
/// wiring of `RippleDeepAgent.make` and `ScreenshotMiddleware`'s non-draining mode. All headless —
/// a fake capture tool seeds `pending_screenshots` so no real screen/permission is needed.
struct DeepAgentVisionTests {
    private func taskCall(_ description: String, _ type: String) -> AgentToolCall {
        AgentToolCall(
            name: "task",
            arguments: ["description": .string(description), "subagent_type": .string(type)]
        )
    }

    private func windowTaskCall(_ description: String, _ type: String, window: Int) -> AgentToolCall {
        AgentToolCall(
            name: "task",
            arguments: [
                "description": .string(description),
                "subagent_type": .string(type),
                "window": .int(window)
            ]
        )
    }

    // MARK: - Factory wiring

    @Test func makeExposesPillarsScreenshotToolAndVisionSubagent() {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        let tools = agent.tools.map(\.name)
        #expect(tools.contains("write_todos")) // planning pillar
        #expect(tools.contains("write_file")) // filesystem pillar
        #expect(tools.contains("task")) // subagents pillar
        #expect(tools.contains("take_screenshot")) // screen capture for the planner
        #expect(tools.contains("list_notes")) // Apple Notes middleware
        #expect(tools.contains("create_note"))
        #expect(tools.contains("update_note"))

        let registry = agent.middleware
            .compactMap { $0 as? SubAgentMiddleware }.first?.registry.map(\.name) ?? []
        #expect(registry.contains("vision"))
    }

    /// Apple Notes writes are gated like file writes: `create_note` / `update_note` need the
    /// user's sign-off, while the reads (`list_notes` / `read_note`) stay ungated.
    @Test func mispherDeepAgentGatesNotesWrites() {
        #expect(Set(RippleDeepAgent.notesApprovals.keys) == ["create_note", "update_note"])
    }

    /// With an approver, `workingDirectory` becomes the real-disk filesystem's root (so ripple's
    /// tools stay scoped to its launch folder), instead of the home-folder default.
    @Test func makeRootsTheRealDiskFilesystemAtTheGivenWorkingDirectory() {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ripple-fs-root", isDirectory: true)
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true),
            approvalHandler: { _ in .reject(message: nil) },
            workingDirectory: work
        )
        let backend = agent.middleware
            .compactMap { $0 as? FilesystemMiddleware }.first?.backend as? LocalFilesystemBackend
        // The backend normalizes its root (symlinks, `..`); compare against a reference built the
        // same way so the assertion survives that normalization.
        #expect(backend?.rootURL == LocalFilesystemBackend(rootURL: work).rootURL)
        #expect(backend?.rootURL != LocalFilesystemBackend().rootURL) // not the home-folder default
    }

    /// Pre-loaded MCP tools join the main agent (alongside the built-in pillars), so a configured
    /// server's tools become callable - the end of "the missing wire".
    @Test func makeAddsMCPToolsToTheMainAgent() {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true),
            mcpTools: [NamedNoopTool(name: "search__web_search"), NamedNoopTool(name: "search__fetch")]
        )
        let tools = agent.tools.map(\.name)
        #expect(tools.contains("search__web_search"))
        #expect(tools.contains("search__fetch"))
        #expect(tools.contains("write_todos")) // pillars still present
    }

    /// Disabling a capability middleware in the policy drops all of its tools; other capabilities
    /// are untouched.
    @Test func makePolicyDisablesACapabilityMiddleware() {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true),
            policy: AgentToolPolicy(disabledMiddleware: ["clipboard"])
        )
        let tools = agent.tools.map(\.name)
        #expect(!tools.contains("read_clipboard"))
        #expect(!tools.contains("write_clipboard"))
        #expect(tools.contains("take_screenshot")) // a different capability stays
        #expect(tools.contains("list_notes"))
    }

    /// Disabling a single tool hides just that tool; its sibling stays available.
    @Test func makePolicyDisablesAnIndividualTool() {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true),
            policy: AgentToolPolicy(disabledTools: ["write_clipboard"])
        )
        let tools = agent.tools.map(\.name)
        #expect(!tools.contains("write_clipboard"))
        #expect(tools.contains("read_clipboard"))
    }

    // MARK: - Image forwarding

    @Test func taskForwardsPendingScreenshotToVisionSubagentThenClearsIt() async {
        let shot = URL(fileURLWithPath: "/tmp/mispher-test-shot.png")
        let seenByFirst = ImageReceiptLog()
        let seenBySecond = ImageReceiptLog()

        // Two vision-style subagents; only the first delegation should receive the forwarded image.
        let visionA = SubAgent(
            name: "vision", description: "sees", systemPrompt: "look",
            tools: [], model: ImageRecordingModel(log: seenByFirst)
        )
        let visionB = SubAgent(
            name: "vision2", description: "sees too", systemPrompt: "look",
            tools: [], model: ImageRecordingModel(log: seenBySecond)
        )

        // Planner: capture (seeds pending) → delegate to vision → delegate again → finish.
        let planner = FakeChatModel(turns: [
            .init(text: "", toolCalls: [AgentToolCall(name: "fake_capture", arguments: [:])]),
            .init(text: "", toolCalls: [taskCall("what is shown?", "vision")]),
            .init(text: "", toolCalls: [taskCall("and now?", "vision2")]),
            .init(text: "done", toolCalls: [])
        ])
        let agent = createDeepAgent(
            model: planner,
            tools: [FakeCaptureTool(url: shot)],
            subagents: [visionA, visionB],
            includeFilesystem: false // keep the subagents tool-free for a focused assertion
        )

        let (ok, _) = await agent.collect([.human("look at my screen")])
        #expect(ok)

        let firstSaw = await seenByFirst.allURLs
        let secondSaw = await seenBySecond.allURLs
        #expect(firstSaw == [shot]) // forwarded into the first vision delegation
        #expect(secondSaw.isEmpty) // cleared afterward — no stale image on the next delegation
    }

    // MARK: - Per-window image forwarding

    @Test func taskForwardsAddressedWindowAndKeepsListForTheNext() async {
        let winA = URL(fileURLWithPath: "/tmp/mispher-test-win-1.png")
        let winB = URL(fileURLWithPath: "/tmp/mispher-test-win-2.png")
        let seenByFirst = ImageReceiptLog()
        let seenBySecond = ImageReceiptLog()

        let visionA = SubAgent(
            name: "vision", description: "sees", systemPrompt: "look",
            tools: [], model: ImageRecordingModel(log: seenByFirst)
        )
        let visionB = SubAgent(
            name: "vision2", description: "sees too", systemPrompt: "look",
            tools: [], model: ImageRecordingModel(log: seenBySecond)
        )

        // Planner: capture every window → analyze window 1 → analyze window 2 → finish.
        let planner = FakeChatModel(turns: [
            .init(text: "", toolCalls: [AgentToolCall(name: "fake_capture_windows", arguments: [:])]),
            .init(text: "", toolCalls: [windowTaskCall("window 1?", "vision", window: 1)]),
            .init(text: "", toolCalls: [windowTaskCall("window 2?", "vision2", window: 2)]),
            .init(text: "done", toolCalls: [])
        ])
        let agent = createDeepAgent(
            model: planner,
            tools: [FakeWindowsCaptureTool(urls: [winA, winB])],
            subagents: [visionA, visionB],
            includeFilesystem: false // keep the subagents tool-free for a focused assertion
        )

        let (ok, _) = await agent.collect([.human("what do I have open?")])
        #expect(ok)

        let firstSaw = await seenByFirst.allURLs
        let secondSaw = await seenBySecond.allURLs
        #expect(firstSaw == [winA]) // window 1 forwarded to the first delegation
        #expect(secondSaw == [winB]) // window 2 still available for the next — list not cleared
    }

    @Test func taskWithOutOfRangeWindowReturnsErrorAndSkipsSubagent() async {
        let win = URL(fileURLWithPath: "/tmp/mispher-test-win-1.png")
        let seen = ImageReceiptLog()
        let vision = SubAgent(
            name: "vision", description: "sees", systemPrompt: "look",
            tools: [], model: ImageRecordingModel(log: seen)
        )
        // Only one window captured, but the planner asks for window 5 — TaskTool fails loud and the
        // subagent never runs (the earlier bug: a vision call with no image hallucinated an answer).
        let planner = FakeChatModel(turns: [
            .init(text: "", toolCalls: [AgentToolCall(name: "fake_capture_windows", arguments: [:])]),
            .init(text: "", toolCalls: [windowTaskCall("window 5?", "vision", window: 5)]),
            .init(text: "done", toolCalls: [])
        ])
        let agent = createDeepAgent(
            model: planner,
            tools: [FakeWindowsCaptureTool(urls: [win])],
            subagents: [vision],
            includeFilesystem: false
        )

        let (ok, _) = await agent.collect([.human("look")])
        #expect(ok)
        let saw = await seen.allURLs
        #expect(saw.isEmpty) // out-of-range: nothing forwarded, subagent skipped
    }

    @Test func taskToVisionWithoutCaptureFailsLoudAndSkipsSubagent() async {
        let seen = ImageReceiptLog()
        let vision = SubAgent(
            name: "vision", description: "sees", systemPrompt: "look",
            tools: [], model: ImageRecordingModel(log: seen)
        )
        // Planner delegates to the (vision-model) subagent without ever capturing. The guard returns
        // an error and the subagent never runs, so it can't hallucinate an answer from no image.
        let planner = FakeChatModel(turns: [
            .init(text: "", toolCalls: [taskCall("what is on screen?", "vision")]),
            .init(text: "done", toolCalls: [])
        ])
        let agent = createDeepAgent(
            model: planner,
            tools: [],
            subagents: [vision],
            includeFilesystem: false
        )

        let (ok, _) = await agent.collect([.human("look")])
        #expect(ok)
        let saw = await seen.allURLs
        #expect(saw.isEmpty) // no capture: vision subagent skipped, nothing forwarded
    }

    // MARK: - Non-draining capture mode

    @Test func nonAttachingModeLeavesPendingForForwarding() async {
        let url = URL(fileURLWithPath: "/tmp/shot.png")
        var state = AgentState(values: [ScreenshotState.pendingKey: [url]])
        await ScreenshotMiddleware(attachToConversation: false).beforeModel(&state)
        #expect((state.values[ScreenshotState.pendingKey] as? [URL]) == [url]) // not drained
        #expect(state.messages.isEmpty) // not spliced into the conversation
    }

    @Test func attachingModeDrainsPendingIntoConversation() async {
        let url = URL(fileURLWithPath: "/tmp/shot.png")
        var state = AgentState(values: [ScreenshotState.pendingKey: [url]])
        await ScreenshotMiddleware().beforeModel(&state)
        #expect(state.values[ScreenshotState.pendingKey] == nil) // drained
        #expect(state.messages.count == 1)
        #expect(state.messages.first?.imageURLs == [url]) // attached to a human turn
    }
}

// MARK: - Test doubles

/// A no-op tool with a chosen name, standing in for a loaded MCP tool in factory-wiring tests.
private struct NamedNoopTool: AgentTool {
    let name: String
    var description: String { "noop" }
    var parameters: [ToolParameter] { [] }

    func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        ToolOutput("ok")
    }
}

/// A fake screen-capture tool: mimics `take_screenshot` by stashing a dummy image URL in
/// `pending_screenshots` (without touching the real screen), so forwarding can be tested headless.
private struct FakeCaptureTool: AgentTool {
    let url: URL
    var name: String { "fake_capture" }
    var description: String { "Pretend to capture the screen." }
    var parameters: [ToolParameter] { [] }

    func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        ToolOutput("captured", stateUpdate: .set(ScreenshotState.pendingKey, [url]))
    }
}

/// A fake all-windows capture tool: mimics `take_window_screenshots` by stashing dummy per-window
/// image URLs in `pending_window_screenshots` (without touching the real screen), so per-window
/// forwarding can be tested headless.
private struct FakeWindowsCaptureTool: AgentTool {
    let urls: [URL]
    var name: String { "fake_capture_windows" }
    var description: String { "Pretend to capture every open window." }
    var parameters: [ToolParameter] { [] }

    func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        ToolOutput(
            "captured windows",
            stateUpdate: .set(ScreenshotState.pendingWindowsKey, urls)
        )
    }
}

/// Records the image URLs a model saw on its human turns across rounds.
private actor ImageReceiptLog {
    private(set) var rounds: [[URL]] = []
    func record(_ urls: [URL]) { rounds.append(urls) }
    var allURLs: [URL] { rounds.flatMap { $0 } }
}

/// A `ChatModel` test double that records the images attached to the messages it's handed (so a test
/// can assert an image was forwarded into a subagent) and streams a fixed no-tool answer.
private struct ImageRecordingModel: ChatModel {
    let log: ImageReceiptLog
    var answer = "saw it"
    var supportsVision = true

    func makeSession() -> any ModelTurnSession {
        ImageRecordingSession(log: log, answer: answer)
    }
}

private final class ImageRecordingSession: ModelTurnSession {
    private let log: ImageReceiptLog
    private let answer: String

    init(log: ImageReceiptLog, answer: String) {
        self.log = log
        self.answer = answer
    }

    func nextTurn(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [any AgentTool],
        onChunk: @escaping @Sendable (AgentStreamChunk) -> Void
    ) async throws -> AgentMessage {
        await log.record(messages.flatMap(\.imageURLs))
        for chunk in FakeChatModel.chunks(answer) { onChunk(.text(chunk)) }
        return .ai(answer, toolCalls: [])
    }
}
