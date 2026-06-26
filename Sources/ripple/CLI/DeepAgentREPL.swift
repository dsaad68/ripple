import Darwin
import DeepAgents
import DeepAgentsMLX
import Foundation

/// Entry point for `ripple chat`: loads the planner + vision models, builds the deep agent, and
/// hands off to the full-screen ``ChatScreen`` TUI (which can rebuild the agent for another planner
/// via the `/model` picker, or for changed settings via `/config`). Requires an interactive terminal.
///
/// `sandbox` (the `--sandbox` flag) force-enables the Apple Container sandbox capability for this
/// session - in the given mode - when the saved policy hasn't already turned it on. A bare
/// `--sandbox` normalizes to `.failover` before reaching here; `nil` leaves the saved policy as-is.
@MainActor
public enum DeepAgentREPL {
    public static func run(
        plannerOverride: String? = nil, logDirectory: String? = nil,
        sandbox: SandboxMode? = nil, autoDownload: Bool = false, resume: ResumeRequest? = nil
    ) async {
        // First run: create an empty `~/.ripple/settings.json` so there's a place to register an
        // OpenAI-compatible model (a no-op once it exists).
        RippleModelConfig.ensureUserFile()

        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            err("ripple chat needs an interactive terminal.")
            return
        }

        let manager = MlxModelLoader()
        // The agent works in the directory `ripple` was launched from (its pwd) - the same root the
        // `@` file picker browses - so its filesystem tools and the picker stay in sync.
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        // Project instructions (AGENTS.md / CLAUDE.md / RIPPLE.md) from the working directory up to the
        // git repo root, merged into the planner's system prompt and listed in the launch banner. Static
        // for the session, so load once and capture in `build` below.
        let instructions = RippleInstructions.load(workingDirectory: workingDirectory)
        // User-registered OpenAI-compatible models (from `.ripple/settings.json`), selectable by name
        // via `--model` and joining the `/model` picker alongside the on-device variants.
        let openAIModels = RippleModelConfig.loadModels(workingDirectory: workingDirectory)
        let variants = DeepAgentVariant.all + openAIModels.map(DeepAgentVariant.remote)

        // Resume: resolve which session to (re)open before anything is built (see `resolveSession`).
        // The id becomes the agent's `threadId`, so its file-backed store loads/saves the right
        // `~/.ripple/sessions/<id>`. A nil result means `--resume <id>` named a missing session.
        guard let resolved = resolveSession(resume, workingDirectory: workingDirectory) else { return }
        let session = resolved.session
        let resumedMeta = resolved.meta
        let resumedMessages = resumedMeta == nil ? [] : RippleSessionStore.messages(id: session.id)

        // The planner to start on, in precedence order: an explicit `--model`, then a resumed
        // session's pinned model, then the project's last-used model (persisted on a `/model` switch),
        // then the built-in default. The stored project model is ignored when it no longer resolves to
        // a known model, so a removed/renamed model can't brick launch.
        let projectModel = RippleAgentConfig.loadSelectedModel(workingDirectory: workingDirectory)
            .flatMap { RippleModelResolution.isKnownModel($0, remote: openAIModels) ? $0 : nil }
        let variant = RippleModelResolution.resolveVariant(
            plannerOverride ?? resumedMeta?.model ?? projectModel, remote: openAIModels
        )
        // A remote variant has nothing on disk to fetch; only MLX variants are gated on downloads. The
        // planner + the configured vision model are fetched now (on disk, not in RAM) so the lazy
        // first-use load doesn't stall on a download.
        let missing = ModelCache.missing(RippleModelResolution.requiredModelIDs(variant, workingDirectory: workingDirectory))
        if !missing.isEmpty {
            guard await ensureDownloaded(missing, autoDownload: autoDownload) else { return }
        }
        // Human-in-the-loop: the agent works on the real working directory, and every file operation
        // suspends for the user's approval in the TUI (see `ApprovalGate`).
        let gate = ApprovalGate()
        // Lets the agent pause to ask the user clarifying questions (the `ask_user` tool); the TUI
        // presents the tabbed card and resumes the run with the answers (see `AskUserGate`).
        let askGate = AskUserGate()

        // MCP servers + tool policy from `.ripple/` (project-local, then ~/.ripple). Tools load once
        // and are reused across `/model` switches; the client's persistent sessions (and any stdio
        // subprocesses) are reaped on exit. OAuth servers sign in via the same browser flow as the app.
        var policy = RippleAgentConfig.loadPolicy(workingDirectory: workingDirectory)
        // `--sandbox <mode>` force-enables the container capability for this session unless the saved
        // policy already turned it on (so a saved container-only isn't downgraded by a bare --sandbox).
        if let sandbox, sandbox != .off, policy.sandbox == .off { policy.sandbox = sandbox }
        // Per-project MCP trust: only this project's accepted servers run (prompting once, pre-TUI,
        // for any not yet decided), each with its per-server approval override applied. See
        // `acceptedServers`.
        let servers = acceptedServers(workingDirectory: workingDirectory)
        // The live MCP layer: connects the servers it can reach (OAuth servers without a cached token
        // are left "not signed in" - their browser flow would block here - until signed in from `/mcp`
        // or `ripple mcp login`). Shared with `ChatScreen` so a `/mcp` sign-in loads tools live, and
        // read by `build` below so each rebuild picks up the current MCP tool set.
        let mcpRuntime = MCPRuntime(servers: servers)
        await mcpRuntime.reload()
        reportMCPStatuses(mcpRuntime.statuses, servers: servers)
        reportInstructions(instructions)

        // `build` takes the policy so a `/config` change (or a `/model` switch) rebuilds with the
        // live capabilities, not a fixed snapshot - and reads the runtime's current MCP tools so a
        // sign-in that happened mid-session is reflected too.
        let build: ChatScreen.Build = { choice, policy in
            // Re-read the user's remote models from `settings.json` so a model registered via the
            // `/models-config` OpenRouter tab this session resolves too - the startup `openAIModels` snapshot
            // wouldn't include it. Cheap (a small JSON file) and only on a `/model` switch or rebuild.
            let remote = RippleModelConfig.loadModels(workingDirectory: workingDirectory)
            // Resolve the planner + (configured) vision as lazy, idle-unloading models - see
            // `RippleModelResolution.deepAgentModels`. Bails if a model can't be resolved.
            guard let models = RippleModelResolution.deepAgentModels(
                choice: choice, manager: manager, workingDirectory: workingDirectory, remote: remote
            ) else { return nil }
            let planner = models.planner
            let vision = models.vision
            // The session's durable checkpoint (resumable history) lives at `~/.ripple/sessions/<id>`,
            // keyed by the current session id (the agent's `threadId`). The debug transcript
            // (`JSONLMessageLog`) is opt-in: off by default, enabled by the `/config` "Logging" toggle
            // or forced on by `--log <dir>` (which also redirects where it lands). Read `session.id`
            // here so a `/fresh` (which mints a new id and rebuilds) retargets both.
            let store = RippleSessionStore(projectPath: workingDirectory, model: choice.textModelID)
            let messageLog = makeMessageLog(
                logDirectory: logDirectory, sessionId: session.id, workingDirectory: workingDirectory
            )
            return RippleDeepAgent.make(
                textModel: planner, visionModel: vision,
                memory: store, approvalHandler: gate.handler, askUserHandler: askGate.handler,
                messageLog: messageLog, workingDirectory: workingDirectory,
                policy: policy, mcpTools: mcpRuntime.tools, mcpApprovalDefaults: mcpRuntime.approvalDefaults,
                projectInstructions: instructions.promptText
            )
        }

        // Warm both models behind a progress bar before entering the full-screen UI; `build` then
        // reuses the cached containers instantly. A tty is guaranteed (checked above), so the bar's
        // carriage-return redraws render cleanly.
        banner(variant)
        // On-device variants warm the planner behind a progress bar before the UI; `build` then reuses
        // the cached container. The vision model is deliberately NOT warmed - it loads lazily on first
        // use (and idle-unloads), so an agent that never looks at the screen never pays for it. A remote
        // variant has nothing to warm (its session is built on demand), so it goes straight to `build`.
        if !variant.isRemote {
            guard await loadWithProgress(manager, variant.textModelID, role: "main agent") != nil else {
                err("failed to load the models.")
                return
            }
        }
        guard let agent = await build(variant, policy) else {
            err("failed to load the models.")
            return
        }
        let screen = ChatScreen(
            variant: variant, agent: agent, build: build, gate: gate, askGate: askGate, variants: variants,
            mcpServers: servers, mcpStatuses: mcpRuntime.statuses, mcpRuntime: mcpRuntime,
            policy: policy, workingDirectory: workingDirectory, sessionContext: session,
            instructionFiles: instructions.labels
        )
        // Resuming: rebuild the on-screen transcript from the stored history so the conversation reads
        // as a continuation. The agent's store loads the same history from disk on the first new turn,
        // so context is carried automatically - this only restores the display.
        if resumedMeta != nil { screen.messages = ChatScreen.restoreTranscript(resumedMessages) }
        await screen.run()
        await mcpRuntime.shutdown() // reap MCP sessions / stdio subprocesses on exit
        // Stop and remove the sandbox container if it was brought up at any point this session.
        if screen.sandboxEverEnabled {
            await AppleContainerSandbox.teardown(for: WorkspaceRoot(rootURL: workingDirectory))
        }
    }

    /// Resolve a `--resume` request to the session to (re)open: a fresh session when there's nothing
    /// to resume, or the stored one (with its meta) by id / from the project picker. Returns nil only
    /// when `--resume <id>` named a session that doesn't exist (the error is already printed).
    private static func resolveSession(
        _ resume: ResumeRequest?, workingDirectory: URL
    ) -> (session: SessionContext, meta: RippleSessionMeta?)? {
        switch resume {
        case .id(let raw):
            guard let meta = RippleSessionStore.meta(id: raw) else {
                err("no such session: \(raw)")
                return nil
            }
            // Scope explicit resume to this project: resuming another project's session here would run
            // its history against the current directory's filesystem, settings, and MCP config.
            guard meta.projectPath == RippleSessionStore.canonicalPath(workingDirectory) else {
                err("session \(raw) belongs to another project (\(meta.projectPath)); cd there to resume it.")
                return nil
            }
            return (SessionContext(id: meta.id), meta)
        case .pick:
            if let chosen = pickSession(RippleSessionStore.sessions(forProject: workingDirectory)) {
                return (SessionContext(id: chosen.id), chosen)
            }
            return (SessionContext(id: UUID().uuidString), nil)
        case nil:
            return (SessionContext(id: UUID().uuidString), nil)
        }
    }

    /// The MCP servers to run this session: the project's enabled, *accepted* servers - prompting once
    /// (pre-TUI) for any not yet decided and persisting the choice to the project `settings.json`, with
    /// each accepted server's optional per-server approval override applied onto its `mcp.json`
    /// `approvalMode`. Declined servers are reported and dropped.
    private static func acceptedServers(workingDirectory: URL) -> [MCPServerConfig] {
        let trust = RippleAgentConfig.loadMCPTrust(workingDirectory: workingDirectory)
        var servers: [MCPServerConfig] = []
        for var server in RippleAgentConfig.loadServers(workingDirectory: workingDirectory).filter(\.isEnabled) {
            let accepted: Bool
            // A decision applies only if it was made for the *same* definition - a server redefined
            // under the same name (new command/url/transport) is re-prompted, not silently trusted.
            if let known = RippleAgentConfig.trustDecided(for: server, in: trust) {
                accepted = known.accepted
                if let override = known.approval { server.approvalMode = override }
            } else {
                accepted = promptAcceptServer(server, changed: trust[server.name] != nil)
                try? RippleAgentConfig.saveMCPTrust(
                    name: server.name, accepted: accepted,
                    fingerprint: RippleAgentConfig.fingerprint(for: server), workingDirectory: workingDirectory
                )
            }
            if accepted {
                servers.append(server)
            } else {
                write("  " + Paint.fg(174, "✗") + " MCP " + Paint.fg(252, server.name)
                    + Paint.fg(240, " · skipped (declined)") + "\n")
            }
        }
        return servers
    }

    /// The MCP servers to run **non-interactively** (headless `-p`): only this project's servers that
    /// were *already* trusted+accepted (for the same definition), each with its per-server approval
    /// override applied. Undecided servers are skipped and returned in `skipped` - a headless run never
    /// prompts, and never *persists* a decision the user hasn't actually seen (unlike ``acceptedServers``,
    /// which records a decline on a non-tty). Decide them once via `ripple chat` or `ripple mcp`.
    static func trustedServers(workingDirectory: URL) -> (servers: [MCPServerConfig], skipped: [String]) {
        let trust = RippleAgentConfig.loadMCPTrust(workingDirectory: workingDirectory)
        var servers: [MCPServerConfig] = []
        var skipped: [String] = []
        for var server in RippleAgentConfig.loadServers(workingDirectory: workingDirectory).filter(\.isEnabled) {
            if let known = RippleAgentConfig.trustDecided(for: server, in: trust), known.accepted {
                if let override = known.approval { server.approvalMode = override }
                servers.append(server)
            } else {
                skipped.append(server.name)
            }
        }
        return (servers, skipped)
    }

    /// Pre-TUI session picker for `ripple --resume` with no id: arrow through this project's past
    /// sessions (most recent first) in ``SessionPicker`` and resume the chosen one. Returns nil to
    /// start fresh - an empty list, a non-interactive stdin, or Esc / `q` / `n`.
    private static func pickSession(_ sessions: [RippleSessionMeta]) -> RippleSessionMeta? {
        guard !sessions.isEmpty else {
            err("no past sessions in this project - starting a new one.")
            return nil
        }
        // Interactive only: without a tty there's nothing to arrow through, so start fresh.
        guard isatty(STDIN_FILENO) != 0, isatty(STDERR_FILENO) != 0 else { return nil }
        return SessionPicker.pick(sessions)
    }

    /// Pre-TUI first-load prompt for an MCP server this project hasn't decided on yet (or whose
    /// definition changed under the same name, when `changed` is true): show what it is and ask whether
    /// to run it here. Defaults to no (declined) - MCP tools are outward-facing, so a non-interactive
    /// launch never silently runs a newly-seen or redefined server.
    private static func promptAcceptServer(_ server: MCPServerConfig, changed: Bool = false) -> Bool {
        let location = server.kind == .http
            ? server.url : ([server.command] + server.args).joined(separator: " ")
        let heading = changed
            ? "MCP server definition changed: " : "New MCP server for this project: "
        write("\n  " + Paint.fg(252, heading) + Paint.bold(server.name) + "\n")
        if !location.isEmpty { write("  " + Paint.fg(240, location) + "\n") }
        write("  run it here? [y/N] ")
        guard isatty(STDIN_FILENO) != 0 else { return false }
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    /// A one-line brand header printed above the load bars (before the full-screen UI takes over).
    private static func banner(_ variant: DeepAgentVariant) {
        let mark = Paint.bold(Paint.gradient("ripple", from: Theme.accent, to: Theme.agent))
        write("\n  " + mark + Paint.fg(240, "  ·  on-device deep agent") + "\n\n")
    }

    /// Print one line per configured MCP server after the initial connect, so a server that failed
    /// to load (a 401, a bad URL) - or an OAuth server that isn't signed in - is visible at launch
    /// instead of silently contributing no tools.
    static func reportMCPStatuses(_ statuses: [MCPServerStatus], servers: [MCPServerConfig]) {
        guard !statuses.isEmpty else { return }
        let oauth = Set(servers.filter { $0.auth == .oauth }.map(\.name))
        for status in statuses {
            if status.connected {
                let suffix = " · \(status.toolCount) tool\(status.toolCount == 1 ? "" : "s")"
                write("  " + Paint.fg(114, "✓") + " MCP " + Paint.fg(252, status.name) + Paint.fg(240, suffix) + "\n")
            } else {
                var line = "  " + Paint.fg(174, "✗") + " MCP " + Paint.fg(252, status.name)
                    + Paint.fg(240, " · " + (status.error ?? "unavailable"))
                if oauth.contains(status.name) { line += Paint.fg(240, "  (run: ripple mcp login \(status.name))") }
                write(line + "\n")
            }
        }
    }

    /// Print one line naming the project instruction files that were loaded (AGENTS.md / CLAUDE.md /
    /// RIPPLE.md, from the working directory up to the repo root), so it's visible at launch that the
    /// agent picked up project guidance - mirroring the MCP status report above. A no-op when none
    /// were found.
    private static func reportInstructions(_ instructions: RippleInstructions.Loaded) {
        guard !instructions.isEmpty else { return }
        let names = instructions.labels.joined(separator: ", ")
        write("  " + Paint.fg(111, "ⓘ") + " instructions" + Paint.fg(240, " · " + names) + "\n")
    }

    /// Ensure every id in `missing` is on disk, downloading each behind a progress bar. With
    /// `autoDownload` (the `--yes` flag) it pulls straight away; otherwise it prints each model's
    /// size and asks once - `[Y/n]`, default yes. A declined prompt (or a non-interactive stdin)
    /// prints how to fetch them with `ripple model pull` and returns false so the caller bails.
    /// `interactive` is false for the headless (`ripple -p`) path: the `[Y/n]` prompt is then skipped
    /// entirely (it would block a non-interactive run), so a missing model without `--yes` just prints
    /// the hint and bails. Returns whether all are present afterwards.
    static func ensureDownloaded(_ missing: [String], autoDownload: Bool, interactive: Bool = true) async -> Bool {
        for id in missing {
            let model = MlxModel.catalog.first { $0.id == id }
            let size = model.map { " (~\($0.sizeLabel))" } ?? ""
            err("model not downloaded: " + (model?.shortName ?? id) + size)
        }
        if !autoDownload {
            // Never prompt when non-interactive (headless) or stdin isn't a tty - print how to fetch and bail.
            guard interactive, isatty(STDIN_FILENO) != 0 else {
                err("run: ripple model pull " + missing.joined(separator: " ") + "   (or launch the Mispher app)")
                return false
            }
            write("  download " + (missing.count == 1 ? "it" : "them") + " now? [Y/n] ")
            let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if answer == "n" || answer == "no" {
                err("ok - fetch later with: ripple model pull " + missing.joined(separator: " "))
                return false
            }
        }
        for id in missing {
            let label = MlxModel.catalog.first { $0.id == id }?.shortName ?? id
            let ok = await CLIProgressBar.run(label: label, verb: "downloading", doneVerb: "downloaded") { progress in
                do {
                    try await ModelCache.download(id, progress: progress)
                    return true
                } catch {
                    return false
                }
            }
            guard ok else { err("failed to download \(label)."); return false }
        }
        return true
    }

    /// Load one model behind ``CLIProgressBar`` (a sweeping bar so the already-downloaded
    /// weight-loading tail never looks frozen). Returns the loaded model, or nil on failure.
    static func loadWithProgress(
        _ loader: MlxModelLoader, _ id: String, role: String
    ) async -> MlxChatModel? {
        let name = MlxModel.catalog.first { $0.id == id }?.shortName ?? id
        var model: MlxChatModel?
        let ok = await CLIProgressBar.run(label: name, role: role) { progress in
            model = await loader.loadChatModel(id) { progress($0) }
            return model != nil
        }
        return ok ? model : nil
    }

    private static func write(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }

    /// The opt-in developer message log for a chat session: `nil` unless `--log <dir>` was passed or
    /// the project's `/config` "Logging" toggle is on (off by default). `--log` also redirects where it
    /// lands; otherwise it goes in the per-session folder beside the resumable `messages.jsonl`.
    static func makeMessageLog(
        logDirectory: String?, sessionId: String, workingDirectory: URL
    ) -> JSONLMessageLog? {
        guard logDirectory != nil || RippleAgentConfig.loadLogMessages(workingDirectory: workingDirectory)
        else { return nil }
        let logDir = logDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? RippleSessionStore.defaultRoot.appendingPathComponent(sessionId, isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        return JSONLMessageLog(directory: logDir)
    }

    private static func err(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// What `ripple --resume` should do: reopen a specific session by id, or list the current project's
/// past sessions and pick one.
public enum ResumeRequest: Sendable {
    case id(String)
    case pick
}

/// The live session identity, shared between the REPL's `build` closure (which targets the session's
/// store + log directory) and ``ChatScreen`` (which mints a new id on `/fresh`). A reference type so
/// both see the same current id - used verbatim as the agent `threadId` - without re-plumbing `build`.
@MainActor
final class SessionContext {
    var id: String
    init(id: String) { self.id = id }
}
