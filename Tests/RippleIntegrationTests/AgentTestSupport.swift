@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import ripple
import Testing

// Test doubles and helpers for the agent framework, modeled on LangChain's testing
// approach: a scripted fake chat model (à la `FakeToolCallingModel`) plus recording
// middleware that append to shared logs so we can assert hook composition/ordering.

/// A scripted `ChatModel` test double — no MLX involved. It vends a `FakeTurnSession`
/// that returns a **sequence of turns, one per ReAct round** (single-shot per round: it
/// emits a turn's tool calls and returns, it does NOT dispatch tools — the *agent* does
/// that and feeds the results back). This exercises the real multi-round loop
/// deterministically.
struct FakeChatModel: ChatModel {
    /// One scripted assistant turn per round.
    struct Turn: Sendable {
        var text: String
        var toolCalls: [AgentToolCall]
        /// Raw tool-call blocks that "failed to parse" — exercises the loop's
        /// malformed-call feedback path.
        var malformedBlocks: [String] = []
        /// Chain-of-thought streamed on the `.reasoning` channel before the visible text — exercises
        /// the reasoning path (`.reasoningToken` events, the reasoning content block).
        var reasoning = ""
    }

    var supportsVision = false
    /// The scripted turns, consumed one per round. After they run out the session returns
    /// an empty no-tool turn, ending the loop.
    var turns: [Turn]

    /// Full control: provide the exact per-round script.
    init(turns: [Turn], supportsVision: Bool = false) {
        self.turns = turns
        self.supportsVision = supportsVision
    }

    /// Convenience: a single final turn that streams `answer` and calls no tools.
    init(answer: String = "ok", supportsVision: Bool = false) {
        self.init(turns: [Turn(text: answer, toolCalls: [])], supportsVision: supportsVision)
    }

    /// Convenience: round 1 emits `toolCalls` (no visible text), round 2 streams `answer`.
    /// Mirrors a one-tool-round ReAct run. With empty `toolCalls` it's a single final turn.
    init(answer: String, toolCalls: [AgentToolCall], supportsVision: Bool = false) {
        let turns =
            toolCalls.isEmpty
                ? [Turn(text: answer, toolCalls: [])]
                : [Turn(text: "", toolCalls: toolCalls), Turn(text: answer, toolCalls: [])]
        self.init(turns: turns, supportsVision: supportsVision)
    }

    func makeSession() -> any ModelTurnSession {
        FakeTurnSession(turns: turns)
    }
}

/// The scripted session: returns `turns[i]` on the i-th `nextTurn`, streaming its text.
final class FakeTurnSession: ModelTurnSession {
    private let turns: [FakeChatModel.Turn]
    private var index = 0

    init(turns: [FakeChatModel.Turn]) { self.turns = turns }

    func nextTurn(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [any AgentTool],
        onChunk: @escaping @Sendable (AgentStreamChunk) -> Void
    ) async throws -> AgentMessage {
        let turn = index < turns.count ? turns[index] : FakeChatModel.Turn(text: "", toolCalls: [])
        index += 1
        for chunk in FakeChatModel.chunks(turn.reasoning) { onChunk(.reasoning(chunk)) }
        for chunk in FakeChatModel.chunks(turn.text) { onChunk(.text(chunk)) }
        return .ai(
            turn.text, toolCalls: turn.toolCalls, malformedToolCallBlocks: turn.malformedBlocks,
            reasoning: turn.reasoning.isEmpty ? nil : turn.reasoning
        )
    }
}

extension FakeChatModel {
    /// Split text into a few chunks to mimic token streaming (reassembles to `answer`).
    static func chunks(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.split(separator: " ", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, part in index == 0 ? String(part) : " " + part }
    }
}

/// A model that emits a tool call on EVERY round and never finishes — used to verify the
/// agent's `maxIterations` safety cap actually terminates the loop. The arguments vary
/// per round so the loop's *duplicate-round* guard (which fires on identical repeated
/// calls — see `StuckToolModel`) doesn't cut the run before the cap is reached.
struct LoopingToolModel: ChatModel {
    var supportsVision = false
    let toolName: String

    func makeSession() -> any ModelTurnSession {
        LoopingToolSession(toolName: toolName)
    }
}

final class LoopingToolSession: ModelTurnSession {
    private let toolName: String
    private var round = 0
    init(toolName: String) { self.toolName = toolName }

    func nextTurn(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [any AgentTool],
        onChunk: @escaping @Sendable (AgentStreamChunk) -> Void
    ) async throws -> AgentMessage {
        round += 1
        return .ai(
            "", toolCalls: [AgentToolCall(name: toolName, arguments: ["text": .string("round \(round)")])]
        )
    }
}

/// A model stuck re-issuing the IDENTICAL tool call every round — until the agent forces
/// the final tool-less turn (`tools` empty), at which point it answers in text. Used to
/// verify the duplicate-round guard stops dispatch and still produces a final answer.
struct StuckToolModel: ChatModel {
    var supportsVision = false
    let toolName: String
    let finalAnswer: String

    func makeSession() -> any ModelTurnSession {
        StuckToolSession(toolName: toolName, finalAnswer: finalAnswer)
    }
}

final class StuckToolSession: ModelTurnSession {
    private let toolName: String
    private let finalAnswer: String
    init(toolName: String, finalAnswer: String) {
        self.toolName = toolName
        self.finalAnswer = finalAnswer
    }

    func nextTurn(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [any AgentTool],
        onChunk: @escaping @Sendable (AgentStreamChunk) -> Void
    ) async throws -> AgentMessage {
        guard tools.isEmpty else {
            return .ai("", toolCalls: [AgentToolCall(name: toolName, arguments: ["text": .string("same")])])
        }
        for chunk in FakeChatModel.chunks(finalAnswer) { onChunk(.text(chunk)) }
        return .ai(finalAnswer)
    }
}

/// Records each model request the agent assembled — once per ReAct round — so tests can
/// assert what middleware composed (system prompt, available tools, message count). It is
/// a middleware (not the model) so it captures the full `ModelRequest`, reflecting
/// `beforeModel` mutations and other middleware's `wrapModelCall` overrides. Register it
/// LAST so it sees the request after outer middleware have edited it.
actor RunRecorder {
    private(set) var systemPrompts: [String?] = []
    private(set) var toolNameSets: [[String]] = []
    private(set) var messageCounts: [Int] = []

    func record(systemPrompt: String?, toolNames: [String], messageCount: Int) {
        systemPrompts.append(systemPrompt)
        toolNameSets.append(toolNames)
        messageCounts.append(messageCount)
    }
}

/// Middleware that records the assembled `ModelRequest` each round into a `RunRecorder`.
struct RequestRecordingMiddleware: AgentMiddleware {
    let recorder: RunRecorder

    func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        await recorder.record(
            systemPrompt: request.systemPrompt,
            toolNames: request.tools.map(\.name),
            messageCount: request.messages.count
        )
        return try await handler(request)
    }
}

/// An append-only log shared by `RecordingMiddleware` instances to capture hook order.
actor CallLog {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}

/// Middleware that records a labeled marker at every hook, so tests can assert the
/// composition and ordering of multiple middleware (LangChain's `execution_log` pattern).
struct RecordingMiddleware: AgentMiddleware {
    let label: String
    let log: CallLog

    var name: String { label }

    func beforeAgent(_ state: inout AgentState) async { await log.add("\(label).beforeAgent") }
    func beforeModel(_ state: inout AgentState) async { await log.add("\(label).beforeModel") }
    func afterModel(_ state: inout AgentState) async { await log.add("\(label).afterModel") }
    func afterAgent(_ state: inout AgentState) async { await log.add("\(label).afterAgent") }

    func wrapModelCall(
        _ request: ModelRequest,
        _ handler: (ModelRequest) async throws -> ModelResponse
    ) async throws -> ModelResponse {
        await log.add("\(label).wrap.before")
        let response = try await handler(request)
        await log.add("\(label).wrap.after")
        return response
    }

    func wrapToolCall(
        _ request: ToolCallRequest,
        _ handler: (ToolCallRequest) async throws -> AgentMessage
    ) async throws -> AgentMessage {
        await log.add("\(label).tool.before")
        let message = try await handler(request)
        await log.add("\(label).tool.after")
        return message
    }
}

/// A trivial tool that echoes its `text` argument — used to test tool dispatch.
struct EchoTool: AgentTool {
    var name: String { "echo" }
    var description: String { "Echo the given text." }
    var parameters: [ToolParameter] {
        [.required("text", type: .string, description: "Text to echo.")]
    }

    func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        if case .string(let text)? = arguments["text"] { return ToolOutput("echo: \(text)") }
        return ToolOutput("echo: <none>")
    }
}

/// A tool that always throws — used to test the dispatcher's error recovery.
struct FailingTool: AgentTool {
    struct Boom: Error {}
    var name: String { "boom" }
    var description: String { "Always fails." }
    func execute(
        _ arguments: [String: AgentJSON], _ context: ToolContext
    ) async throws -> ToolOutput {
        throw Boom()
    }
}

extension ReactAgent {
    /// Run the agent and collect every emitted event, in order. Convenience for tests:
    /// the run completes (buffering events into the stream) before we drain them.
    func collect(
        _ input: [AgentMessage], threadId: String? = nil
    ) async -> (ok: Bool, events: [AgentEvent]) {
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        let ok = await run(input, threadId: threadId) { continuation.yield($0) }
        continuation.finish()
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return (ok, events)
    }
}

extension [AgentEvent] {
    /// All streamed answer tokens, concatenated (across all rounds — see `finalAnswer`
    /// for just the final round's text).
    var tokenText: String {
        compactMap { if case .token(let t, _) = $0 { return t } else { return nil } }.joined()
    }

    /// All streamed reasoning tokens, concatenated (the `.reasoningToken` channel).
    var reasoningText: String {
        compactMap { if case .reasoningToken(let t) = $0 { return t } else { return nil } }.joined()
    }

    /// The committed final answer: the text streamed during the final (no-tool) round,
    /// reconstructed using the `roundCompleted` boundaries the way the UI does.
    var finalAnswer: String {
        var committed = ""
        var current = ""
        for event in self {
            switch event {
            case .token(let t, _): current += t
            case .roundCompleted(let hadToolCalls):
                if hadToolCalls { current = "" } else { committed = current; current = "" }
            default: break
            }
        }
        return committed
    }

    /// The `hadToolCalls` flag of each `roundCompleted`, in order.
    var roundCompletions: [Bool] {
        compactMap { if case .roundCompleted(let h) = $0 { return h } else { return nil } }
    }

    var toolStartedNames: [String] {
        compactMap { if case .toolStarted(let n, _) = $0 { return n } else { return nil } }
    }

    var toolStarts: [(name: String, input: String)] {
        compactMap { if case .toolStarted(let n, let i) = $0 { return (n, i) } else { return nil } }
    }

    var toolCompletedResults: [(name: String, result: String)] {
        compactMap {
            if case .toolCompleted(let n, let r, _, _) = $0 { return (n, r) } else { return nil }
        }
    }

    var toolFailedNames: [String] {
        compactMap { if case .toolFailed(let n, _) = $0 { return n } else { return nil } }
    }

    var toolFailures: [(name: String, error: String)] {
        compactMap { if case .toolFailed(let n, let e) = $0 { return (n, e) } else { return nil } }
    }

    var todoUpdates: [[TodoItem]] {
        compactMap { if case .todosUpdated(let t) = $0 { return t } else { return nil } }
    }

    var didComplete: Bool {
        contains { if case .completed = $0 { return true } else { return false } }
    }

    var didFail: Bool {
        contains { if case .failed = $0 { return true } else { return false } }
    }
}
