import DeepAgents
import DeepAgentsMLX
import Foundation

// The chat screen's view-model types, split out of ChatScreen.swift to keep that file within budget.
// They are module-internal (not file-private) so ChatScreen and its rendering extension can share them.

struct Message {
    enum Kind {
        case user(String)
        case assistant(Assistant)
        case bang(BangCommand) // a `!` / `!!` command the user ran directly (see `BangCommand`)
        case note(String) // a dim system line (e.g. a context-compaction notice)
    }

    let kind: Kind
}

/// A shell command the user ran straight from the input box with a bang prefix - `!cmd` in the
/// container sandbox, `!!cmd` in the local shell - bypassing the agent and its approval card (the
/// user typed it themselves, so it runs at once). A reference type, mutated in place as its output
/// streams and then replaced with the authoritative result.
@MainActor
final class BangCommand {
    /// Where the command runs: the Apple Container sandbox (`!`) or the local shell (`!!`).
    enum Target { case container, local }

    let command: String
    let target: Target
    var expanded = false // user clicked to reveal output beyond the first few lines
    private(set) var output = ""
    private(set) var status: Int32? // the command's exit code, once it finishes
    private(set) var failed = false // couldn't launch / the sandbox was unavailable
    private(set) var interrupted = false // the user stopped it (esc / ctrl-c)
    private(set) var running = true
    let startedAt = Date()
    private(set) var seconds: Double? // wall-clock once it ends

    init(command: String, target: Target) {
        self.command = command
        self.target = target
    }

    /// Append a streamed output chunk while the command runs (ignored once it has finished, so a
    /// late chunk can't land after the authoritative result has replaced the stream).
    func stream(_ chunk: String) { if running { output += chunk } }

    /// Replace the streamed output with the authoritative combined result and stamp the exit code -
    /// mirrors how the shell tool formats a `ProcessRunner.Result` (stdout+stderr, exit/timeout note).
    func complete(_ result: ProcessRunner.Result) {
        guard running else { return }
        var body = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        if result.timedOut {
            body += (body.isEmpty ? "" : "\n") + "[Command timed out and was killed.]"
        } else if result.status != 0 {
            body += (body.isEmpty ? "" : "\n") + "[Exited with status \(result.status).]"
        }
        output = body.isEmpty ? "(no output)" : body
        status = result.status
        end()
    }

    /// The command couldn't run at all (e.g. the container sandbox is unavailable): show the reason.
    func fail(_ message: String) { guard running else { return }; output = message; failed = true; end() }

    /// The user stopped it; the process finishes in the background and its output is dropped.
    func stop() { guard running else { return }; interrupted = true; end() }

    private func end() {
        running = false
        if seconds == nil { seconds = Date().timeIntervalSince(startedAt) }
    }
}

/// How gated tool calls (ls / read_file / write_file / edit_file) are handled. Cycled with Tab.
enum PermissionMode: CaseIterable {
    case ask // prompt for every gated call (default)
    case autoReads // auto-approve reads (ls / read_file), prompt for writes
    case plan // dry run: auto-approve reads, auto-reject writes (nothing is changed)
    case acceptAll // approve everything without asking (YOLO)

    var label: String {
        switch self {
        case .ask: "ASK"
        case .autoReads: "AUTO-READS"
        case .plan: "PLAN"
        case .acceptAll: "ACCEPT ALL"
        }
    }

    /// The banner color: green ask, amber auto-reads, blue plan, red accept-all.
    var color: Theme.Color {
        switch self {
        case .ask: Theme.success
        case .autoReads: Theme.warn
        case .plan: Theme.accent
        case .acceptAll: Theme.danger
        }
    }

    static let reads: Set<String> = ["ls", "read_file"]

    /// The auto-decision for a gated `toolName` under this mode, or nil to prompt the user. Shared
    /// by the interactive ``ChatScreen`` (which first honors its session allowlist) and the
    /// non-interactive headless runner (which has no one to prompt, so it treats nil as a rejection).
    func decision(for toolName: String) -> ToolApprovalDecision? {
        let isRead = Self.reads.contains(toolName)
        switch self {
        case .ask: return nil
        case .autoReads: return isRead ? .approve : nil
        case .acceptAll: return .approve
        case .plan: return isRead ? .approve : .reject(message: "Plan mode: the change was not applied.")
        }
    }
}

/// One rendered screen line, optionally clickable. `highlight` paints the row as a selection band
/// (a full-width background) when it's drawn inside a menu panel.
struct Line {
    let text: String
    let action: ClickAction?
    let highlight: Bool

    init(_ text: String, _ action: ClickAction? = nil, highlight: Bool = false) {
        self.text = text
        self.action = action
        self.highlight = highlight
    }
}

/// What a left-click on a rendered line does.
enum ClickAction {
    case toggleThought(Reasoning)
    case toggleStep(Step)
    case toggleStepThought(Step) // a delegate step's subagent reasoning
    case toggleBang(BangCommand) // expand / collapse a bang command's output
    case togglePlan // collapse / expand the pinned plan panel
    case runCommand(Int)
    case resolveApproval(Bool) // true = approve, false = reject
    case alwaysAllowTool // approve and remember this tool for the session
    case editApproval // edit the command before running (shell card)
    case selectAskUserChoice(Int) // pick a choice row in the ask_user card (last index = "Other")
    case submitAskUser // confirm the highlighted choice / advance the ask_user card
    case selectFile(Int)
    case openToolGroup(Int) // open a toolset in the `/tools` browser
    case jumpToLatest
}

/// The `/tools` browser: the agent's prebuilt tools grouped by toolset (the middleware that
/// contributes them). Level 1 lists the groups; opening one (`openGroup`) shows that toolset's
/// tools with their descriptions and parameters. Built fresh from the live agent each time it's
/// opened, so it always reflects the current planner's stack.
struct ToolsBrowser {
    /// One parameter of a tool, pre-rendered for display: `label` is "name (required, string)",
    /// `detail` the description (plus any allowed `enum` values).
    struct Param {
        let label: String
        let detail: String
    }

    struct ToolInfo {
        let name: String
        let gated: Bool // needs the human-in-the-loop approval card before it runs
        let description: String
        let params: [Param]
    }

    struct Group {
        let title: String
        /// An optional dimmed line under the title (e.g. an MCP server's transport / auth /
        /// approval, or a model's id), shown in both the list and the detail header.
        var subtitle: String?
        let tools: [ToolInfo]
        /// A pre-painted right-hand label that replaces the "N tools" count (the `/model` overlay's
        /// Local / Remote tabs use it for the size + ✓/○ downloaded marker). Nil for the tool/MCP browsers.
        var trailing: String?
        /// For the `/model` overlay's Local / Remote tabs: whether this model is on disk / added (gates
        /// the `x` remove key).
        var downloaded = false
    }

    /// The overlay heading - "Tools by toolset" for `/tools`, "MCP servers" for `/mcp`.
    var title = "Tools by toolset"
    /// Shown when there are no groups (e.g. no MCP servers configured).
    var emptyMessage = "This agent has no tools."
    /// True for the `/mcp` browser: enables the per-server sign-in keys (`r` (re)auth, `x` log out)
    /// and their footer hint, which don't apply to the `/tools` browser.
    var isMCP = false
    /// True for the `/model` overlay's Local tab: rows are downloadable models (enter pulls, `x` removes)
    /// rather than tool groups, and the right-hand label is the size + downloaded marker, not a tool
    /// count.
    var isModels = false
    /// True for the `/model` overlay's Remote (OpenRouter) tab: rows are free OpenRouter models (enter
    /// toggles add/remove in `~/.ripple/settings.json`, `x` removes), and the right-hand label is an
    /// added/not-added marker.
    var isOpenRouter = false
    /// An optional warning shown under the title (e.g. "`OPENROUTER_API_KEY` not set").
    var banner: String?
    let groups: [Group]
    var groupIndex = 0 // highlighted group in the list (level 1)
    var openGroup: Int? // nil = group list; otherwise the opened group's index (level 2)

    var current: Group? { openGroup.flatMap { groups.indices.contains($0) ? groups[$0] : nil } }

    mutating func move(_ delta: Int) {
        guard !groups.isEmpty else { return }
        groupIndex = (groupIndex + delta + groups.count) % groups.count
    }
}

/// The `/config` settings editor: two tabs (switched with ←/→) - **Capabilities** (the middleware
/// toggles + developer log) and **Sandbox** (the container's three-way ``SandboxMode`` + image). It
/// edits a working copy of the ``AgentToolPolicy`` plus the developer-log toggle; ``ChatScreen``
/// persists and applies them on close. (Model selection lives in the unified `/model` overlay.)
struct ConfigEditor {
    /// The panel's two tabs, switched with ←/→.
    enum Tab: CaseIterable {
        case capabilities, sandbox, cache
        var title: String {
            switch self {
            case .capabilities: "Capabilities"
            case .sandbox: "Sandbox"
            case .cache: "Cache"
            }
        }
    }

    /// One row on the active tab.
    struct Row {
        let id: String
        let displayName: String
        let summary: String
        var isContainer: Bool { id == "container" }
    }

    var tab: Tab = .capabilities
    var index = 0

    /// The working copy applied + saved when the editor closes.
    var policy: AgentToolPolicy
    /// Working copy of the developer message-log toggle (a Ripple setting, not part of the tool policy).
    var logMessages: Bool
    /// Working copy of the prefix-KV disk-cache toggle (a Ripple setting, not part of the tool policy).
    var prefixKVCache: Bool

    /// Working copies of the prefix-cache limits (Ripple settings, not part of the tool policy).
    var snapshotsPerModel: Int
    var maxGigabytes: Double
    /// What the store holds, scanned when the editor opens. Empty until then.
    var inventory: PrefixKVStore.Inventory = .empty

    static let logRowID = "devlog"
    static let prefixKVRowID = "prefixkv"
    static let snapshotsRowID = "prefixkv.snapshots"
    static let sizeRowID = "prefixkv.size"
    static let clearRowID = "prefixkv.clear"
    /// A per-model usage row carries its model id after this prefix, so `x` knows what to delete.
    static let modelRowPrefix = "prefixkv.model:"

    /// The counts offered on the Snapshots row, cycled with space.
    static let snapshotChoices = [2, 4, 6, 8, 12]
    /// The ceilings offered on the Size row, in GB. `0` is "no limit".
    static let sizeChoices: [Double] = [1, 2, 4, 8, 16, 0]

    init(
        policy: AgentToolPolicy, logMessages: Bool = false, prefixKVCache: Bool = true,
        snapshotsPerModel: Int = 6, maxGigabytes: Double = 4
    ) {
        self.policy = policy
        self.logMessages = logMessages
        self.prefixKVCache = prefixKVCache
        self.snapshotsPerModel = snapshotsPerModel
        self.maxGigabytes = maxGigabytes
    }

    /// A byte count in the same shape the model rows use elsewhere.
    static func size(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    /// The rows shown on the active tab: the capability toggles (+ logging) or the container sandbox.
    var rows: [Row] {
        switch tab {
        case .capabilities:
            return MiddlewareCatalog.all.map { Row(id: $0.id, displayName: $0.displayName, summary: $0.summary) }
                + [
                    Row(
                        id: Self.logRowID, displayName: "Logging",
                        summary: "Write a developer message log (JSONL, with timing and tool steps) to the "
                            + "session folder for debugging. Off by default; separate from the resumable history."
                    )
                ]
        case .sandbox:
            let container = MiddlewareCatalog.container
            return [Row(id: container.id, displayName: container.displayName, summary: container.summary)]
        case .cache:
            return cacheRows
        }
    }

    /// The Cache tab: the on/off switch, the two limits, then what the store is actually holding.
    /// Usage rows are informational - `x` on one deletes that model's snapshots.
    private var cacheRows: [Row] {
        var rows = [
            Row(
                id: Self.prefixKVRowID, displayName: "Prefill cache",
                summary: "Keep the reusable prompt prefix (system prompt + tool schemas KV) on disk "
                    + "under ~/.cache/deepagents/prefix-kv, so a fresh launch resumes it and skips "
                    + "the multi-second prompt prefill. Off writes nothing; what is already saved stays."
            ),
            Row(
                id: Self.snapshotsRowID, displayName: "Snapshots",
                summary: "How many saved prefixes to keep per model. Per model, not overall, so a "
                    + "planner you use occasionally keeps its warm prefix instead of being evicted "
                    + "by the one you use all day. Space cycles."
            ),
            Row(
                id: Self.sizeRowID, displayName: "Size limit",
                summary: "Ceiling on the snapshots' total size - the oldest go first once it is "
                    + "passed, and the newest is never evicted. A count alone would not bound this: "
                    + "one model's snapshot can run to a few hundred MB. Space cycles."
            )
        ]
        guard !inventory.models.isEmpty || inventory.unattributedBytes > 0 else { return rows }
        rows.append(
            Row(
                id: Self.clearRowID, displayName: "All models",
                summary: "Everything the store is holding. Press x to delete all of it - it is "
                    + "derived, so this costs one slower turn per model and nothing else."
            )
        )
        for usage in inventory.models {
            rows.append(
                Row(
                    id: Self.modelRowPrefix + usage.modelID,
                    displayName: MlxModel.catalog.first { $0.id == usage.modelID }?.shortName ?? usage.modelID,
                    summary: "\(usage.modelID) - \(usage.snapshotCount) snapshot"
                        + (usage.snapshotCount == 1 ? "" : "s")
                        + ", \(usage.traceCount) trace" + (usage.traceCount == 1 ? "" : "s")
                        + ". Press x to delete this model's saved prefixes."
                )
            )
        }
        if inventory.unattributedBytes > 0 {
            rows.append(
                Row(
                    id: Self.modelRowPrefix, displayName: "Other files",
                    summary: "\(inventory.unattributedCount) file"
                        + (inventory.unattributedCount == 1 ? "" : "s")
                        + " that name no model, usually left by an older build. Removed by All models."
                )
            )
        }
        return rows
    }

    /// The model id a usage row deletes, or nil for any other row.
    func modelID(of row: Row) -> String? {
        guard row.id.hasPrefix(Self.modelRowPrefix) else { return nil }
        let id = String(row.id.dropFirst(Self.modelRowPrefix.count))
        return id.isEmpty ? nil : id
    }

    var current: Row? { rows.indices.contains(index) ? rows[index] : nil }

    mutating func move(_ delta: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        index = (index + delta + rows.count) % rows.count
    }

    /// Switch tabs with ←/→, resetting the row cursor to the top of the new tab.
    mutating func switchTab(_ delta: Int) {
        let all = Tab.allCases
        guard let i = all.firstIndex(of: tab) else { return }
        tab = all[(i + delta + all.count) % all.count]
        index = 0
    }

    // MARK: - Capability / sandbox state

    /// The local shell is governed by the sandbox and not user-toggleable whenever the sandbox is on
    /// (failover forces it on, container-only off). An override - it never mutates `disabledMiddleware`,
    /// so the user's own shell choice is restored once the sandbox is off.
    func isLocked(_ row: Row) -> Bool { row.id == "shell" && policy.sandbox.isEnabled }

    /// The next value after `current` in `choices`, wrapping. An unrecognised current value (a
    /// hand-edited settings.json) lands on the first choice rather than sticking.
    static func cycle<T: Equatable>(_ current: T, through choices: [T]) -> T {
        guard let index = choices.firstIndex(of: current) else { return choices[0] }
        return choices[(index + 1) % choices.count]
    }

    /// The resolved sandbox image - the configured override, or the built-in default.
    var containerImage: String { policy.sandboxImage ?? AppleContainerSandbox.defaultImage }

    /// Is `row` on? The shell follows the sandbox governance; the container uses the sandbox mode;
    /// everything else uses `disabledMiddleware`.
    func isOn(_ row: Row) -> Bool {
        if row.id == Self.logRowID { return logMessages }
        if row.id == Self.prefixKVRowID { return prefixKVCache }
        // The limits and usage rows aren't switches; `stateLabel` shows their value instead.
        if isCacheValueRow(row) { return true }
        if row.id == "shell" { return policy.localShellEnabled }
        return row.isContainer ? policy.sandbox.isEnabled : !policy.disabledMiddleware.contains(row.id)
    }

    /// The state label shown on the right of a row.
    func stateLabel(_ row: Row) -> String {
        if isLocked(row) { return isOn(row) ? "on - fail over" : "off - container only" }
        if row.isContainer { return policy.sandbox.label }
        if row.id == Self.snapshotsRowID { return "\(snapshotsPerModel) per model" }
        if row.id == Self.sizeRowID {
            return maxGigabytes == 0 ? "no limit" : String(format: "%.0f GB", maxGigabytes)
        }
        if row.id == Self.clearRowID { return Self.size(inventory.totalBytes) }
        if let model = modelID(of: row) {
            return Self.size(inventory.models.first { $0.modelID == model }?.bytes ?? 0)
        }
        if row.id == Self.modelRowPrefix { return Self.size(inventory.unattributedBytes) }
        return isOn(row) ? "on" : "off"
    }

    /// Rows on the Cache tab that carry a value rather than an on/off state.
    func isCacheValueRow(_ row: Row) -> Bool {
        row.id == Self.snapshotsRowID || row.id == Self.sizeRowID
            || row.id == Self.clearRowID || row.id.hasPrefix(Self.modelRowPrefix)
    }

    /// Toggle the highlighted capability / sandbox / logging row on space (the container cycles its
    /// sandbox mode). A locked row can't toggle.
    mutating func toggle() {
        guard let row = current, !isLocked(row) else { return }
        if row.id == Self.logRowID {
            logMessages.toggle()
        } else if row.id == Self.prefixKVRowID {
            prefixKVCache.toggle()
        } else if row.id == Self.snapshotsRowID {
            snapshotsPerModel = Self.cycle(snapshotsPerModel, through: Self.snapshotChoices)
        } else if row.id == Self.sizeRowID {
            maxGigabytes = Self.cycle(maxGigabytes, through: Self.sizeChoices)
        } else if isCacheValueRow(row) {
            return // usage rows are read-only; `x` deletes
        } else if row.isContainer {
            policy.sandbox = Self.nextSandbox(policy.sandbox)
        } else if policy.disabledMiddleware.contains(row.id) {
            policy.disabledMiddleware.remove(row.id)
        } else {
            policy.disabledMiddleware.insert(row.id)
        }
    }

    static func nextSandbox(_ mode: SandboxMode) -> SandboxMode {
        switch mode {
        case .off: .failover
        case .failover: .containerOnly
        case .containerOnly: .off
        }
    }
}

/// One reasoning block (`<think>…</think>`) inside an assistant turn. Streams live while the model
/// is thinking, then collapses to "Thought for Xs" once the block ends - a tool call, the answer, or
/// the turn finishing. A reference type so a click can toggle its `expanded` disclosure by identity
/// and its text can grow in place.
@MainActor
final class Reasoning {
    private(set) var text = ""
    private(set) var seconds: Double? // wall-clock once the block ends; nil while it is still streaming
    var expanded = false // user clicked the collapsed thought to reveal the reasoning

    private let startedAt = Date()

    func append(_ chunk: String) { text += chunk }
    func finish() { if seconds == nil { seconds = Date().timeIntervalSince(startedAt) } }
    /// Still streaming (not yet ended) - render the live `thinking…` tail rather than the collapse.
    var streaming: Bool { seconds == nil }
}

/// A run of answer text inside an assistant turn (the model's visible, non-`<think>` output). A
/// reference type so it grows in place as tokens stream.
@MainActor
final class AnswerText {
    private(set) var text = ""
    func append(_ chunk: String) { text += chunk }
}

/// One assistant turn, mutated in place as the agent streams. Its reasoning, tool calls, plan
/// updates, and answer are kept as an ordered ``Block`` timeline - in the exact sequence the model
/// produced them (reason → tool → reason → answer) - so a multi-round ReAct turn renders in order
/// instead of grouped by type.
@MainActor
final class Assistant {
    /// What an assistant turn is made of, recorded in arrival order.
    enum Block {
        case reasoning(Reasoning)
        case step(Step)
        case answer(AnswerText)
    }

    private(set) var blocks: [Block] = []
    private(set) var tokenCount = 0 // streamed answer-token events (first-token phase detection)
    private(set) var interrupted = false
    /// The run's `.failed` message (a model that couldn't load, a generation error), rendered as a
    /// red error line under the turn - a failed turn must never end as a silent empty answer.
    private(set) var failure: String?

    // Live decode-rate tracking. Counts *every* generated token (reasoning + answer) and sums
    // only the time spent actively decoding: inter-token gaps above `stallGap` are prefill, tool
    // execution, or round transitions - counting them as generation time is what made the old
    // `tokenCount / turnElapsed` readout collapse on reasoning models and tool runs.
    private(set) var generatedTokens = 0
    private var generationSeconds: TimeInterval = 0
    private var lastTokenAt: Date?
    private static let stallGap: TimeInterval = 1.0

    /// Tokens per second of active decoding, once there is enough signal for a stable reading.
    var tokensPerSecond: Double? {
        guard generatedTokens >= 8, generationSeconds > 0.25 else { return nil }
        return Double(generatedTokens) / generationSeconds
    }

    /// Record one generated token (answer or reasoning) for the rate readout. `now` is
    /// injectable for tests.
    func noteToken(at now: Date = Date()) {
        generatedTokens += 1
        if let last = lastTokenAt {
            let gap = now.timeIntervalSince(last)
            if gap < Self.stallGap { generationSeconds += gap }
        }
        lastTokenAt = now
    }

    private var openReasoning: Reasoning? // the reasoning block currently streaming, if any
    private var openAnswer: AnswerText? // the answer run currently streaming, if any

    /// All answer text produced this turn, concatenated (for the context-size meter).
    var answer: String {
        blocks.compactMap { if case .answer(let run) = $0 { return run.text } else { return nil } }.joined()
    }

    func consume(_ event: AgentEvent) {
        switch event {
        case .token(let chunk, _): tokenCount += 1; noteToken(); appendAnswer(chunk)
        case .reasoningToken(let chunk): noteToken(); appendReasoning(chunk)
        case .roundCompleted: break
        case .toolStarted(let name, let input, let callID, let batchID):
            closeText()
            blocks.append(.step(Step(kind: .tool(name: name, detail: input, output: "",
                                                 ok: true, done: false, subagent: Self.subagent(name, input)),
                callID: callID, batchID: batchID)))
            countBatch(batchID)
        case .toolProgress(_, _, let delta, let callID):
            appendToolOutput(delta, done: false, ok: true, callID: callID)
        case .toolCompleted(_, let result, _, let diff, let callID):
            appendToolOutput(result, done: true, ok: true, replace: true, diff: diff, callID: callID)
        case .toolFailed(_, let error, let callID):
            appendToolOutput(error, done: true, ok: false, replace: true, callID: callID)
        case .todosUpdated: closeText() // the plan lives in the pinned panel, not the transcript
        case .contextCompacted: break // surfaced as a transcript note by the turn, not this block
        case .failed(let message): failure = message
        case .completed: break
        }
    }

    func complete() { closeText() }

    func interrupt() { closeText(); interrupted = true }

    /// Rebuild a finished assistant turn from a persisted `.ai` message (and the tool results that
    /// followed it), for rendering a resumed transcript - blocks added in reasoning → tool steps →
    /// answer order, then the turn closed. Used only off the live event stream (see
    /// ``ChatScreen/restoreTranscript(_:)``), never during a running turn.
    func restore(reasoning: String?, steps: [Step], answer: String) {
        if let reasoning, !reasoning.isEmpty {
            let block = Reasoning()
            block.append(reasoning)
            block.finish()
            blocks.append(.reasoning(block))
        }
        for step in steps { blocks.append(.step(step)) }
        if !answer.isEmpty {
            let run = AnswerText()
            run.append(answer)
            blocks.append(.answer(run))
        }
        complete()
    }

    /// Flush buffered tokens and end any open reasoning/answer run, so the next event starts a fresh
    /// block: a tool call, a plan update, or the turn finishing all "close" the current text.
    private func closeText() {
        openReasoning?.finish()
        openReasoning = nil
        openAnswer = nil
    }

    /// Append streamed answer text to the open answer run (its own `.token` channel), ending any
    /// open reasoning block first - stamping its duration - and opening a new answer block in
    /// timeline order.
    private func appendAnswer(_ text: String) {
        guard !text.isEmpty else { return }
        openReasoning?.finish()
        openReasoning = nil
        if openAnswer == nil {
            let run = AnswerText()
            blocks.append(.answer(run))
            openAnswer = run
        }
        openAnswer?.append(text)
    }

    /// Append streamed chain-of-thought (its own `.reasoningToken` channel) to the open reasoning
    /// block, ending any open answer run first and opening a new reasoning block in timeline order.
    private func appendReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        openAnswer = nil
        if openReasoning == nil {
            let reasoning = Reasoning()
            blocks.append(.reasoning(reasoning))
            openReasoning = reasoning
        }
        openReasoning?.append(text)
    }

    /// Stamp every step of `batchID` with how many calls are now known to be in it, so each card
    /// can show the size of the group it ran with. The batch announces all of its calls before any
    /// of them finishes, so the count is settled before the first result lands.
    private func countBatch(_ batchID: UUID?) {
        guard let batchID else { return }
        let siblings = blocks.compactMap { block -> Step? in
            guard case .step(let step) = block, step.batchID == batchID else { return nil }
            return step
        }
        for step in siblings { step.batchSize = siblings.count }
    }

    /// Fill in a tool step's output. `callID` names the call this belongs to - the round's tools
    /// can run in parallel, so several steps are open at once and "the last unfinished one" is no
    /// longer the right card. Without an id (an event a host synthesized) fall back to that.
    private func appendToolOutput(
        _ text: String, done: Bool, ok: Bool, replace: Bool = false,
        diff: FileDiff? = nil, callID: UUID? = nil
    ) {
        for block in blocks.reversed() {
            guard case .step(let step) = block,
                  case .tool(let name, let detail, let output, _, let isDone, let sub) = step.kind,
                  !isDone else { continue }
            if let callID, step.callID != callID { continue }
            step.kind = .tool(name: name, detail: detail,
                              output: replace ? text : output + text, ok: ok, done: done, subagent: sub)
            if let diff { step.diff = diff }
            if done, step.seconds == nil { step.seconds = Date().timeIntervalSince(step.startedAt) }
            return
        }
    }

    private static func subagent(_ name: String, _ input: String) -> String? {
        guard name == "task", let range = input.range(of: "subagent_type: ") else { return nil }
        let value = input[range.upperBound...].prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// A step in an assistant turn (a tool call - plan updates are pinned separately, see
/// ``ChatScreen/plan``). A reference type so its output can grow in place and a click can toggle its
/// `expanded` disclosure by identity.
@MainActor
final class Step {
    enum Kind {
        case tool(name: String, detail: String, output: String, ok: Bool, done: Bool, subagent: String?)
    }

    var kind: Kind
    var expanded = false // for a delegate step this shows/hides the subagent's result
    var thinkExpanded = false // a delegate step's subagent reasoning (collapsed by default)
    var diff: FileDiff? // an edit_file's line diff, rendered as a diff card (nil for other tools)
    let startedAt = Date()
    var seconds: Double? // wall-clock once the call finishes
    /// The tool call this step shows, so progress and results reach the right card when a round
    /// runs several tools at once. `nil` for a step rebuilt from a persisted transcript.
    let callID: UUID?
    /// The concurrent batch this call ran in, shared with its siblings; `nil` when it ran alone.
    let batchID: UUID?
    /// How many calls ran together in that batch, kept up to date as the batch's cards open. `1`
    /// means "ran on its own", and is what the card renders as no indicator at all.
    var batchSize = 1

    init(kind: Kind, callID: UUID? = nil, batchID: UUID? = nil) {
        self.kind = kind
        self.callID = callID
        self.batchID = batchID
    }
}

extension ChatScreen {
    /// Rebuild the display transcript from a resumed session's `[AgentMessage]`: each human turn
    /// becomes a prompt box, each `.ai` turn an assistant block (its reasoning, then a tool step per
    /// tool call - filled with the result from the matching `.tool` message - then its answer text).
    /// `.system` and `.tool` messages produce no standalone line (tool output is folded into its
    /// step). This only restores what's shown; the agent's store reloads the real history from disk.
    static func restoreTranscript(_ history: [AgentMessage]) -> [Message] {
        // Pair each tool result to the call it answers, so a restored step shows its output.
        var results: [UUID: String] = [:]
        for message in history where message.role == .tool {
            if let id = message.toolCallID { results[id] = message.text }
        }
        var out: [Message] = []
        for message in history {
            // Compaction-synthesized turns: show the summary as a dim note and drop the synthetic ack,
            // so a resumed compacted session doesn't render the summary as a fake user prompt or the
            // ack as a fake assistant reply (mirrors the live `/compact` note and the app's resume).
            if message.isSummary {
                if message.role == .human { out.append(Message(kind: .note("Earlier conversation summarized."))) }
                continue
            }
            switch message.role {
            case .human:
                out.append(Message(kind: .user(message.text)))
            case .ai:
                let steps = message.toolCalls.map { call in
                    Step(kind: .tool(
                        name: call.name, detail: call.describedArguments,
                        output: results[call.id] ?? "", ok: true, done: true,
                        subagent: subagentType(call)
                    ))
                }
                let assistant = Assistant()
                assistant.restore(reasoning: message.reasoning, steps: steps, answer: message.text)
                out.append(Message(kind: .assistant(assistant)))
            case .system, .tool:
                continue
            }
        }
        return out
    }

    /// The subagent a restored `task` call delegated to (its `subagent_type` argument), or nil for a
    /// plain tool call - mirrors the live `Assistant.subagent(_:_:)` detection.
    private static func subagentType(_ call: AgentToolCall) -> String? {
        guard call.name == "task", case .string(let value)? = call.arguments["subagent_type"] else { return nil }
        return value.isEmpty ? nil : value
    }
}
