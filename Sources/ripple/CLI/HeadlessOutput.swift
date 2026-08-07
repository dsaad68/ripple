import DeepAgents
import Foundation

/// The output shape of a headless (`ripple -p`) run. `text` streams the agent's final answer to
/// stdout (tool/diagnostic noise to stderr); `json` emits a single result object at the end;
/// `stream-json` emits one JSON object per agent event live, then a final result line. Across all
/// three, **stdout carries only the answer / JSON** so the command pipes cleanly - everything else
/// (progress bars, model load, tool activity) goes to stderr.
enum OutputFormat: String, CaseIterable, Sendable {
    case text
    case json
    case streamJSON = "stream-json"
}

/// Where a renderer writes: `out` is stdout (the answer / JSON), `err` is stderr (diagnostics). Made
/// injectable so the renderers are unit-testable without capturing the process's file handles.
struct HeadlessSink {
    var out: (String) -> Void
    var err: (String) -> Void

    /// The process sink: `out` -> stdout, `err` -> stderr. Computed (the closures are stateless) so
    /// it isn't a shared-mutable global.
    static var standard: HeadlessSink {
        HeadlessSink(
            out: { FileHandle.standardOutput.write(Data($0.utf8)) },
            err: { FileHandle.standardError.write(Data($0.utf8)) }
        )
    }
}

/// The terminal summary of a headless run, handed to a renderer's ``HeadlessRenderer/finish(_:)``.
/// `HeadlessRun` accumulates this from the event stream (the final answer is the visible text of the
/// last no-tool round); the renderer only decides how to format it.
struct HeadlessResult: Sendable {
    /// The agent's final visible answer (reasoning and interim pre-tool text excluded).
    let answer: String
    /// `agent.run` returned `true` (the run reached a clean completion).
    let ok: Bool
    /// At least one tool call was blocked by the permission mode (no one to approve it headlessly).
    let blocked: Bool
    /// Tool names that started, in order (duplicates kept - one per call).
    let toolsUsed: [String]
    /// ReAct rounds that completed.
    let rounds: Int
    /// The planner model id the run used.
    let model: String
    /// The `.failed` message, when the run failed.
    let error: String?
}

/// Consumes a headless run: each live ``AgentEvent`` via ``handle(_:)``, then exactly one
/// ``finish(_:)`` with the terminal summary. Implementations write through a ``HeadlessSink``.
protocol HeadlessRenderer: AnyObject {
    func handle(_ event: AgentEvent)
    func finish(_ result: HeadlessResult)
}

extension OutputFormat {
    /// The renderer for this format, writing through `sink`.
    func makeRenderer(sink: HeadlessSink = .standard) -> any HeadlessRenderer {
        switch self {
        case .text: TextRenderer(sink: sink)
        case .json: JSONRenderer(sink: sink)
        case .streamJSON: StreamJSONRenderer(sink: sink)
        }
    }
}

// MARK: - text

/// Default format: the final answer (only) to stdout; tool starts/failures and the error, if any,
/// as concise lines to stderr. Tokens aren't streamed live - a one-shot answer is buffered and
/// printed whole so stdout is exactly the result (`stream-json` is the format for live tokens).
final class TextRenderer: HeadlessRenderer {
    private let sink: HeadlessSink
    init(sink: HeadlessSink) { self.sink = sink }

    func handle(_ event: AgentEvent) {
        switch event {
        case .toolStarted(let name, let input, _, _):
            let detail = input.isEmpty ? "" : ": \(input.replacingOccurrences(of: "\n", with: " "))"
            sink.err("· \(name)\(detail)\n")
        case .toolFailed(let name, let error, _):
            sink.err("· \(name) failed: \(error)\n")
        default:
            break
        }
    }

    func finish(_ result: HeadlessResult) {
        if let error = result.error { sink.err("error: \(error)\n") }
        guard !result.answer.isEmpty else { return }
        sink.out(result.answer.hasSuffix("\n") ? result.answer : result.answer + "\n")
    }
}

// MARK: - json (single result object)

/// Emits one pretty-printed `result` object to stdout at the end of the run; ignores live events.
final class JSONRenderer: HeadlessRenderer {
    private let sink: HeadlessSink
    init(sink: HeadlessSink) { self.sink = sink }

    func handle(_ event: AgentEvent) {}

    func finish(_ result: HeadlessResult) {
        sink.out(jsonLine(ResultLine(result), pretty: true))
    }
}

// MARK: - stream-json (JSONL)

/// Emits one compact JSON object per line: a tagged ``EventLine`` per live event, then a final
/// `result` line.
final class StreamJSONRenderer: HeadlessRenderer {
    private let sink: HeadlessSink
    init(sink: HeadlessSink) { self.sink = sink }

    func handle(_ event: AgentEvent) {
        if let line = EventLine(event) { sink.out(jsonLine(line, pretty: false)) }
    }

    func finish(_ result: HeadlessResult) {
        sink.out(jsonLine(ResultLine(result), pretty: false))
    }
}

// MARK: - JSON envelopes

/// A tagged snapshot of one ``AgentEvent`` for `stream-json` (the event enum isn't `Codable`). Only
/// the fields relevant to `type` are populated; the rest stay nil and are omitted.
struct EventLine: Encodable {
    let type: String
    var text: String?
    var isFinal: Bool?
    var name: String?
    var input: String?
    var result: String?
    var error: String?
    var subagent: String?
    var delta: String?
    var hadToolCalls: Bool?
    var imageURL: String?
    var todos: [TodoLine]?
    var tokensBefore: Int?
    var tokensAfter: Int?
    /// The tool call a `tool_*` line belongs to. A round's tools can run in parallel, so their
    /// lines interleave - this is what a consumer pairs on instead of `name`.
    var callID: String?
    /// Set on the `tool_started` lines of calls that ran concurrently, shared by the batch, so a
    /// consumer can tell "three calls, one wait" from three sequential ones.
    var batchID: String?

    struct TodoLine: Encodable {
        let content: String
        let status: String
    }

    init?(_ event: AgentEvent) {
        switch event {
        case .token(let text, let isFinal):
            type = "token"; self.text = text; self.isFinal = isFinal
        case .reasoningToken(let text):
            type = "reasoning"; self.text = text
        case .roundCompleted(let hadToolCalls):
            type = "round_completed"; self.hadToolCalls = hadToolCalls
        case .toolStarted(let name, let input, let callID, let batchID):
            type = "tool_started"; self.name = name; self.input = input
            self.callID = callID?.uuidString
            self.batchID = batchID?.uuidString
        case .toolProgress(let name, let subagent, let delta, let callID):
            type = "tool_progress"; self.name = name; self.subagent = subagent; self.delta = delta
            self.callID = callID?.uuidString
        case .toolCompleted(let name, let result, let imageURL, _, let callID):
            type = "tool_completed"; self.name = name; self.result = result
            self.imageURL = imageURL?.absoluteString
            self.callID = callID?.uuidString
        case .toolFailed(let name, let error, let callID):
            type = "tool_failed"; self.name = name; self.error = error
            self.callID = callID?.uuidString
        case .todosUpdated(let items):
            type = "todos"; todos = items.map { TodoLine(content: $0.content, status: $0.status.rawValue) }
        case .contextCompacted(let before, let after):
            type = "context_compacted"; tokensBefore = before; tokensAfter = after
        case .completed:
            type = "completed"
        case .failed(let error):
            type = "failed"; self.error = error
        }
    }
}

/// The terminal `result` object, shared by `json` (pretty) and `stream-json` (the last line).
struct ResultLine: Encodable {
    let type = "result"
    let subtype: String
    let result: String
    let isError: Bool
    let toolsUsed: [String]
    let numTurns: Int
    let permissionBlocked: Bool
    let model: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type, subtype, result
        case isError = "is_error"
        case toolsUsed = "tools_used"
        case numTurns = "num_turns"
        case permissionBlocked = "permission_blocked"
        case model, error
    }

    init(_ summary: HeadlessResult) {
        subtype = summary.ok ? "success" : "error"
        result = summary.answer
        isError = !summary.ok
        toolsUsed = summary.toolsUsed
        numTurns = summary.rounds
        permissionBlocked = summary.blocked
        model = summary.model
        error = summary.error
    }
}

/// Encode `value` as one JSON line (trailing newline). `pretty` for the single `json` object;
/// compact for `stream-json` lines. Slashes are left unescaped so paths/URLs read naturally.
func jsonLine(_ value: some Encodable, pretty: Bool) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty
        ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        : [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        return "\n"
    }
    return text + "\n"
}
