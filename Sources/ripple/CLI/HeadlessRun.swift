import Darwin
import DeepAgents
import DeepAgentsMLX
import Foundation

/// The flags that drive a non-interactive (`ripple -p`) run. Built by the CLI layer (``Ripple``) from
/// the parsed arguments and handed to ``HeadlessRun/run(_:)``. `--allow-tool` / `--deny-tool` /
/// `--disable-middleware` / `--sandbox*` fold into the loaded ``AgentToolPolicy``; `permissionMode`
/// drives the non-interactive approval handler for whatever the policy still gates.
struct HeadlessOptions: Sendable {
    var promptArg: String?
    var outputFormat: OutputFormat = .text
    var permissionMode: PermissionMode = .ask
    var model: String?
    var allowTools: [String] = []
    var denyTools: [String] = []
    var disableMiddleware: [String] = []
    /// nil leaves the saved policy's sandbox mode untouched; a value overrides it for this run.
    var sandbox: SandboxMode?
    var sandboxImage: String?
    var logDirectory: String?
    var autoDownload = false

    /// Overlay this run's flags onto a base policy: `--allow-tool` -> approve, `--deny-tool` -> deny,
    /// `--disable-middleware` -> off, plus the sandbox mode/image. (Pure, so it's unit-tested directly.)
    func overlay(onto base: AgentToolPolicy) -> AgentToolPolicy {
        var policy = base
        for tool in allowTools { policy.approvals[tool] = .approve }
        for tool in denyTools { policy.approvals[tool] = .deny }
        for id in disableMiddleware { policy.disabledMiddleware.insert(id) }
        if let sandbox { policy.sandbox = sandbox }
        if let sandboxImage { policy.sandboxImage = sandboxImage }
        return policy
    }
}

/// One-shot, non-interactive deep-agent run for `ripple -p "..."` (or piped stdin). Builds the same
/// agent as ``DeepAgentREPL`` (reusing its model-resolution / download / MCP helpers) but with no TUI:
/// a non-interactive approval handler stands in for the human-in-the-loop card, and the agent's event
/// stream is rendered straight to stdout/stderr per ``OutputFormat``.
///
/// Exit codes (returned to the CLI, which turns a non-zero into `ExitCode`):
/// - `0` the agent run completed.
/// - `1` the agent run itself failed (a `.failed` event / model error mid-run).
/// - `2` setup/config error before the run could start (no prompt; the model is unavailable, not
///   downloaded, or failed to load).
/// - `3` the run completed but a tool was blocked by the permission mode (precedence below failure).
///
/// Setup failures (`2`) are reported *through the renderer* too, so `--output-format json`/`stream-json`
/// always emit a machine-readable error object on stdout rather than just a human line on stderr.
@MainActor
enum HeadlessRun {
    /// Tracks whether the permission mode blocked any gated tool call (set off the main actor by the
    /// approval handler, read back here at the end). Internal so the drive loop is unit-testable.
    actor BlockFlag {
        private(set) var raised = false
        func raise() { raised = true }
    }

    static func run(_ options: HeadlessOptions) async -> Int32 {
        // First run: make sure there's a `~/.ripple/settings.json` to read models/policy from.
        RippleModelConfig.ensureUserFile()
        // Built up front so setup failures below can report through it (a JSON error object on stdout
        // for json/stream-json), not just a human line on stderr.
        let renderer = options.outputFormat.makeRenderer()

        guard let prompt = resolvePrompt(options.promptArg) else {
            return fail("no prompt - pass -p \"...\" or pipe text on stdin", renderer: renderer)
        }

        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let openAIModels = RippleModelConfig.loadModels(workingDirectory: workingDirectory)

        // Policy: the project's saved policy, overlaid with this run's flags. `--allow-tool`/`--deny-tool`
        // set per-tool approvals (so `make` never even gates an allowed tool, and auto-rejects a denied
        // one); the rest map one-to-one onto policy fields.
        let policy = options.overlay(onto: RippleAgentConfig.loadPolicy(workingDirectory: workingDirectory))
        // The prefix-KV disk cache honors the same `/config` toggle as the REPL (settings.json).
        PrefixKVStore.isEnabledOverride = RippleAgentConfig.loadPrefixKVCache(workingDirectory: workingDirectory)

        // Model: same precedence as the REPL (--model -> project selectedModel -> default), through the
        // shared `RippleModelResolution` so the two paths stay in lockstep.
        let projectModel = RippleAgentConfig.loadSelectedModel(workingDirectory: workingDirectory)
            .flatMap { RippleModelResolution.isKnownModel($0, remote: openAIModels) ? $0 : nil }
        let variant = RippleModelResolution.resolveVariant(options.model ?? projectModel, remote: openAIModels)
        // Download the planner + the configured vision model (else the variant default) so the lazy
        // first-use load doesn't stall.
        let missing = ModelCache.missing(RippleModelResolution.requiredModelIDs(variant, workingDirectory: workingDirectory))
        if !missing.isEmpty {
            // `interactive: false` so a missing model never blocks on a `[Y/n]` prompt - headless prints
            // the `ripple model pull` hint and bails unless `--yes` was passed.
            guard await DeepAgentREPL.ensureDownloaded(missing, autoDownload: options.autoDownload, interactive: false)
            else { return fail("model not available: \(missing.joined(separator: ", "))", model: variant.textModelID, renderer: renderer) }
        }

        let manager = MlxModelLoader()
        // On-device variants warm the planner behind a stderr progress bar; the vision model loads
        // lazily on first use (and idle-unloads), so a one-shot that never looks at the screen never
        // pays for it. A remote variant has nothing on disk to warm (its session is built on demand).
        if !variant.isRemote {
            guard await DeepAgentREPL.loadWithProgress(manager, variant.textModelID, role: "main agent") != nil
            else {
                // Surface the loader's recorded reason (as `ripple chat` does) - the blanket
                // message alone made real load bugs (e.g. a VLM processor config mismatch)
                // undiagnosable from a headless run.
                let reason = manager.lastLoadError.map { ": \($0)" } ?? "."
                return fail("failed to load the models\(reason)", model: variant.textModelID, renderer: renderer)
            }
        }
        // Resolve the planner + (configured) vision as lazy, idle-unloading models - the same
        // `RippleModelResolution.deepAgentModels` helper `ripple chat` uses, so the two can't drift.
        guard let models = RippleModelResolution.deepAgentModels(
            choice: variant, manager: manager, workingDirectory: workingDirectory, remote: openAIModels
        ) else {
            return fail("failed to load model: \(variant.textModelID)", model: variant.textModelID, renderer: renderer)
        }
        let planner = models.planner
        let vision = models.vision

        // MCP: only servers already trusted+accepted for this project (a headless run never prompts or
        // persists a trust decision the user hasn't seen). Undecided servers are reported and dropped.
        let (servers, skipped) = DeepAgentREPL.trustedServers(workingDirectory: workingDirectory)
        for name in skipped {
            errLine("MCP \(name) · skipped (not trusted yet; decide via `ripple chat` or `ripple mcp`)")
        }
        let mcpRuntime = MCPRuntime(servers: servers)
        await mcpRuntime.reload()
        DeepAgentREPL.reportMCPStatuses(mcpRuntime.statuses, servers: servers)

        // Deny-and-continue approvals: a tool the mode can't auto-approve is rejected with a hint and the
        // agent keeps going. allow/deny tools already folded into `policy`, so they never reach here.
        let flag = BlockFlag()
        let permissionMode = options.permissionMode
        let approvalHandler: ToolApprovalHandler = { request in
            if let decision = permissionMode.decision(for: request.toolName) { return decision }
            await flag.raise()
            return .reject(message: "non-interactive: \(request.toolName) needs approval "
                + "(use --permission-mode accept-all or --allow-tool \(request.toolName))")
        }

        let logURL = options.logDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let logURL { try? FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true) }

        let agent = RippleDeepAgent.make(
            textModel: planner, visionModel: vision,
            memory: nil, // stateless one-shot - the agent just starts fresh
            approvalHandler: approvalHandler,
            askUserHandler: { _ in .cancelled }, // no one to ask non-interactively; the agent continues
            messageLog: logURL.map { JSONLMessageLog(directory: $0) },
            workingDirectory: workingDirectory,
            policy: policy, mcpTools: mcpRuntime.tools, mcpApprovalDefaults: mcpRuntime.approvalDefaults
        )

        let result = await drive(
            agent: agent, prompt: prompt, model: variant.textModelID, renderer: renderer, blocked: flag
        )

        await mcpRuntime.shutdown() // reap MCP sessions / stdio subprocesses
        if policy.sandbox.isEnabled { // best-effort stop/remove of the sandbox container if it came up
            await AppleContainerSandbox.teardown(for: WorkspaceRoot(rootURL: workingDirectory))
        }

        return exitCode(ok: result.ok, blocked: result.blocked)
    }

    /// Report a setup failure (exit code `2`) through `renderer`, so `json`/`stream-json` emit a
    /// machine-readable error object on stdout (and `text` prints `error: <message>` to stderr) before
    /// the agent ever runs.
    private static func fail(_ message: String, model: String = "", renderer: any HeadlessRenderer) -> Int32 {
        renderer.finish(HeadlessResult(
            answer: "", ok: false, blocked: false, toolsUsed: [], rounds: 0, model: model, error: message
        ))
        return 2
    }

    /// Process exit code from a run's outcome: `0` success, `1` failure, `3` a tool was blocked by the
    /// permission mode. Failure takes precedence over a block. (Pure, so it's unit-tested directly.)
    nonisolated static func exitCode(ok: Bool, blocked: Bool) -> Int32 {
        if !ok { return 1 }
        return blocked ? 3 : 0
    }

    /// Run the single turn, draining the agent's event stream into `renderer` while accumulating the
    /// terminal summary. The final answer is the visible text of the last round that made no tool calls
    /// (interim pre-tool text is discarded); a truncated run falls back to its last round's text.
    /// Internal (not private) so it's unit-testable with a scripted model.
    static func drive(
        agent: ReactAgent, prompt: String, model: String,
        renderer: any HeadlessRenderer, blocked: BlockFlag
    ) async -> HeadlessResult {
        var roundText = ""
        var finalText = ""
        var tools: [String] = []
        var rounds = 0
        var failure: String?

        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let runTask = Task.detached {
            let ok = await agent.run([.human(prompt)], threadId: nil) { continuation.yield($0) }
            continuation.finish()
            return ok
        }
        for await event in events {
            renderer.handle(event)
            switch event {
            case .token(let text, _):
                roundText += text
            case .roundCompleted(let hadToolCalls):
                rounds += 1
                if hadToolCalls { roundText = "" } else { finalText = roundText; roundText = "" }
            case .toolStarted(let name, _):
                tools.append(name)
            case .failed(let message):
                failure = message
            default:
                break
            }
        }
        let ok = await runTask.value
        if finalText.isEmpty { finalText = roundText } // truncated / no clean final round

        let result = await HeadlessResult(
            answer: finalText, ok: ok, blocked: blocked.raised,
            toolsUsed: tools, rounds: rounds, model: model,
            error: failure ?? (ok ? nil : "the run failed")
        )
        renderer.finish(result)
        return result
    }

    /// The prompt for this run: the `-p` value, the piped stdin, or both (the explicit prompt first,
    /// the piped text appended as context). Returns nil when neither yields any text.
    private static func resolvePrompt(_ arg: String?) -> String? {
        let explicit = arg?.trimmingCharacters(in: .whitespacesAndNewlines)
        let piped = readStdinIfPiped()
        switch (explicit?.isEmpty == false ? explicit : nil, piped) {
        case (let explicit?, let piped?): return explicit + "\n\n" + piped
        case (let explicit?, nil): return explicit
        case (nil, let piped?): return piped
        case (nil, nil): return nil
        }
    }

    /// Stdin's contents when it's piped (not a terminal), trimmed; nil for an interactive tty or empty
    /// input. Guarded on `isatty` so a `-p` run in a terminal never blocks waiting for stdin.
    private static func readStdinIfPiped() -> String? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func errLine(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
