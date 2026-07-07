import DeepAgents
import DeepAgentsMacTools
import Foundation

/// Ripple's concrete deep agent: a text **planner** (LFM2.5 8B-A1B) that breaks work into todos,
/// keeps working state on the shared filesystem, and delegates isolated subtasks — including
/// **vision** — to subagents. Built on the generic
/// ``createDeepAgent(model:tools:systemPrompt:subagents:middleware:memory:backend:interruptOn:approvalHandler:includeFilesystem:includeGeneralPurpose:maxIterations:messageLog:)``,
/// so the planning / filesystem / subagent pillars come for free.
///
/// The planner is blind (a text model), so it can't look at the screen itself. It captures with
/// `take_screenshot` via a non-attaching ``ScreenshotMiddleware`` (the image is left in
/// `pending_screenshots` rather than spliced into the planner's own conversation, where it would be
/// useless), then hands that capture to the `vision` subagent. ``SubAgentMiddleware``'s `task` tool
/// forwards the pending screenshot into the subagent's first turn, and the `vision` subagent runs
/// the VL model (`supportsVision: true`) — the only model in this setup that can actually see it.
enum RippleDeepAgent {
    /// Build the deep agent. `textModel` is the planner (8B-A1B); `visionModel` is the VL model
    /// (1.6B) the `vision` subagent runs on and the only one that renders the forwarded image.
    ///
    /// `approvalHandler` is the human-in-the-loop bridge: when present, the filesystem tools work
    /// on the user's real disk - rooted at `workingDirectory` when given (e.g. the folder `ripple`
    /// was launched from), else the home folder - and every `read_file` / `write_file` /
    /// `edit_file` call — from the planner or any subagent — suspends until the user approves or
    /// denies it in the HUD. Without an approver there is deliberately no disk access: the agent
    /// falls back to the in-memory scratch filesystem (and `workingDirectory` is ignored).
    ///
    /// `policy` is the user's middleware/tool activation + approval choices (which capabilities
    /// run, which tools are hidden, and Approve/Ask/Deny per tool). `mcpTools` are the tools the
    /// caller already loaded from the configured MCP servers - they join the **main** agent (not
    /// the subagents); `mcpApprovalDefaults` carries each MCP tool's default approval (the
    /// per-server mode), overridable by `policy`.
    static func make(
        textModel: any ChatModel,
        visionModel: (any ChatModel)? = nil,
        memory: (any AgentCheckpointer)? = nil,
        approvalHandler: ToolApprovalHandler? = nil,
        askUserHandler: AskUserHandler? = nil,
        messageLog: (any AgentMessageLog)? = nil,
        workingDirectory: URL? = nil,
        policy: AgentToolPolicy = .init(),
        mcpTools: [any AgentTool] = [],
        mcpApprovalDefaults: [String: ToolApprovalMode] = [:],
        projectInstructions: String? = nil
    ) -> ReactAgent {
        // The `vision` subagent (and the screenshot capture that feeds it) only exists when there's
        // a VLM to run it — a text-only remote planner has no vision model, so both are dropped.
        let vision = visionModel.map { model in
            SubAgent(
                name: "vision",
                description: "Looks at a screenshot the deep agent just captured and answers questions "
                    + "about what is visible (text, UI, errors, layout). Capture with take_screenshot or "
                    + "take_window_screenshots first, then delegate the visual question here — for a "
                    + "specific window pass its number as `window`.",
                systemPrompt: DeepVisionPrompt.system,
                tools: [], // pure analysis — the image is forwarded into its first turn
                model: model // the VL model; the only one that can see the forwarded image
            )
        }

        // Gating (and real-disk / real-system access) only applies when there's an approver to
        // ask. The command-line tools that read the disk or touch the system (`search`, `text`,
        // `git`, `macos`) are wired only then, rooted at the same working folder as the
        // filesystem tools - so without an approver the agent stays on the in-memory scratch
        // filesystem with no disk/system reach, exactly as before. `web` (fetch/curl) is
        // network-only, so it's always available.
        let gated = approvalHandler != nil
        let workspace = WorkspaceRoot(rootURL: workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser)

        // Capability middleware - screen capture (non-attaching: the blind planner forwards
        // captures to the vision subagent), the clipboard, Apple Notes, and the command-line
        // tools - minus any the user turned off. MCP tools (already loaded) ride along as one
        // more middleware contributing to the main agent. Each middleware brings its own prompt
        // guidance with its tools.
        var middleware: [any AgentMiddleware] = []
        // Screen capture is pointless without a vision subagent to forward the (non-attached)
        // capture to, so it rides along only when one exists.
        if vision != nil {
            middleware.append(ScreenshotMiddleware(attachToConversation: false))
        }
        middleware += [
            ClipboardMiddleware(),
            AppleNotesMiddleware(),
            WebToolsMiddleware()
        ]
        if gated {
            middleware += [
                SearchToolsMiddleware(root: workspace),
                TextToolsMiddleware(root: workspace),
                GitToolsMiddleware(root: workspace),
                MacToolsMiddleware(root: workspace)
            ]
            // The local shell is governed by the sandbox mode - off in container-only, forced on in
            // failover, user-controlled otherwise (see `AgentToolPolicy.localShellEnabled`).
            if policy.localShellEnabled {
                middleware.append(ShellToolsMiddleware(root: workspace))
            }
            // The container sandbox sits alongside the local shell, but only when the user has
            // turned it on (it needs Apple's `container` tool); the `sandbox` mode both enables it
            // and picks its fail behavior.
            if policy.sandbox.isEnabled {
                middleware.append(ContainerShellMiddleware(
                    root: workspace, mode: policy.sandbox, image: policy.sandboxImage
                ))
            }
        }
        // Shell presence is governed above (failover forces it on even past a stale disable), so it's
        // exempt from the generic disable filter.
        middleware = middleware.filter { $0.name == "shell" || !policy.disabledMiddleware.contains($0.name) }
        if !mcpTools.isEmpty { middleware.append(MCPMiddleware(tools: mcpTools)) }

        // MCP tools default to "ask" (outward-facing - they do whatever the server does),
        // overridable per server; built-in defaults come from the catalog.
        var mcpDefaults: [String: ToolApprovalMode] = [:]
        for tool in mcpTools { mcpDefaults[tool.name] = .ask }
        for (name, mode) in mcpApprovalDefaults { mcpDefaults[name] = mode }
        // `container_shell` isn't a catalog capability (it's opt-in via the sandbox mode), so seed
        // its default gating here - ask before running, like the local shell.
        mcpDefaults["container_shell"] = .ask
        var expansion = policy.expand(extraDefaults: mcpDefaults)
        // Let a gated shell command be edited in the approval card, not just approved or rejected.
        if expansion.interruptOn["shell"] != nil {
            expansion.interruptOn["shell"] = InterruptOnConfig(allowedDecisions: [.approve, .edit, .reject])
        }

        // Deny-mode tools are auto-rejected before they ever reach the user. (Catastrophic `shell`
        // commands are blocked one layer earlier, in `ShellToolsMiddleware.wrapToolCall`, so they
        // never reach the approval card at all.)
        let handler = approvalHandler.map {
            denyEnforcingApprovalHandler($0, denyToolNames: expansion.denyToolNames)
        }

        // The planner's own guidance, followed by any project instructions (AGENTS.md / CLAUDE.md /
        // RIPPLE.md loaded from the working directory up to the repo root). `createDeepAgent` composes
        // this after its base deep-agent prompt.
        let systemPrompt = [DeepScreenPrompt.system, projectInstructions]
            .compactMap { $0 }
            .joined(separator: "\n\n")

        return createDeepAgent(
            model: textModel,
            systemPrompt: systemPrompt,
            subagents: vision.map { [$0] } ?? [],
            middleware: middleware,
            memory: memory,
            backend: gated ? LocalFilesystemBackend(rootURL: workspace.rootURL) : nil,
            interruptOn: gated ? expansion.interruptOn : [:],
            approvalHandler: handler,
            // The agent can ask the user clarifying questions whenever a handler is wired - the REPL
            // always provides one. Like the planning/subagent scaffolding it's on by default (not a
            // `/config` toggle), but an explicit `ask_user` entry in `disabledMiddleware` is still
            // honored, mirroring the `includeFilesystem` check below.
            askUserHandler: policy.disabledMiddleware.contains("ask_user") ? nil : askUserHandler,
            includeFilesystem: !policy.disabledMiddleware.contains("filesystem"),
            disabledToolNames: expansion.disabledToolNames,
            messageLog: messageLog
        )
    }

    /// The human-in-the-loop policy for the real-disk filesystem: every file operation needs
    /// the user's sign-off. `ls` is gated alongside the reads and writes - on the real disk it
    /// can reveal sensitive file and folder names under the user's home directory, so listing
    /// is disk access too.
    static let fileApprovals: [String: InterruptOnConfig] = [
        "ls": InterruptOnConfig(),
        "read_file": InterruptOnConfig(),
        "write_file": InterruptOnConfig(),
        "edit_file": InterruptOnConfig()
    ]

    /// The human-in-the-loop policy for Apple Notes: writes need the user's sign-off (the
    /// approval card shows the title/body/mode being written, so a wrong-note overwrite is
    /// caught before it happens). Reads (`list_notes` / `read_note`) stay ungated.
    static let notesApprovals: [String: InterruptOnConfig] = [
        "create_note": InterruptOnConfig(),
        "update_note": InterruptOnConfig()
    ]
}
