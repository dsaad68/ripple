import DeepAgents
import DeepAgentsMLX
import Foundation

/// The full-screen `ripple chat` UI: a scrolling content area (user prompts in filled boxes, a
/// live `◆ thinking…` reasoning stream that collapses to `◆ Thought for Xs`, the streamed answer,
/// a plan panel, and tree-style tool steps), a pinned bottom input box, and a status line carrying
/// the working directory + context meter + current model. Drives the deep agent, supports scrolling
/// (arrows / page keys), and a unified `/model` overlay to choose + manage models at runtime. Needs a tty.
///
/// The class is split across topic files, all `extension ChatScreen`: input routing
/// (ChatScreenInput), input-box editing + `@file` mentions (ChatScreenEditing), the turn loop +
/// approvals (ChatScreenTurn), the view layer (ChatScreenRender + ChatScreenApprovalCard +
/// ChatScreenTranscript + ChatScreenBanner), and the `/config` + `/tools` overlays (ChatScreenConfig
/// + ChatScreenTools). The shared view-model types live in ChatScreenModel.
@MainActor
final class ChatScreen {
    /// Loads/rebuilds the deep agent for a chosen variant and tool policy (reuses warm model
    /// containers). The policy is passed (not captured) so a `/config` change rebuilds with it.
    typealias Build = @MainActor (DeepAgentVariant, AgentToolPolicy) async -> ReactAgent?

    var variant: DeepAgentVariant
    /// Every selectable variant: the on-device presets plus any configured remote (OpenAI-compatible)
    /// models. A `var` so the `/model` overlay's Remote (OpenRouter) tab can rebuild it (via
    /// ``reloadRemoteModels()``) when a model is added or removed, with no restart.
    var variants: [DeepAgentVariant]
    var agent: ReactAgent
    let build: Build
    /// The live tool policy (capabilities + approvals + sandbox), edited by `/config` and fed back
    /// into `build` to rebuild the agent. Persisted to `.ripple/tool-policy.json` under the working
    /// directory when set.
    var policy: AgentToolPolicy
    /// Whether the developer message log is on for this project (a Ripple setting toggled in `/config`,
    /// off by default). The `build` closure reads the persisted value, so a `/config` change rebuilds
    /// the agent with or without the log; tracked here for the editor's initial state + change detection.
    var logMessages = false
    /// Whether the prefix-KV disk cache is on for this project (a Ripple setting toggled in `/config`,
    /// on by default). Applied to ``PrefixKVStore`` at launch and on `/config` changes - it takes
    /// effect on the next turn, no agent rebuild needed.
    var prefixKVCache = true
    /// The display name of a model currently cold-loading from disk, or nil (the REPL wires this to
    /// ``MlxModelLoader/loadingModelID``). Read by the working line so a lazy (re)load after an
    /// idle-unload is labeled as the model loading rather than looking like slow prompt processing.
    let modelLoadStatus: @MainActor () -> String?
    let workingDirectory: URL?
    /// The project instruction files loaded at launch (AGENTS.md / CLAUDE.md / RIPPLE.md, repo-root
    /// relative labels), listed in the launch banner. Empty when none were found.
    let instructionFiles: [String]
    /// True once the container sandbox has been enabled this session, so the REPL knows to tear the
    /// container down on exit even if it was later turned back off.
    var sandboxEverEnabled = false
    /// True while the user is typing a custom container image into the `/config` editor's Container
    /// row. Keystrokes then fall through to the shared input buffer (see ``routeModalByte``), mirroring
    /// the ask_user "Other" free-text entry; Enter commits, Esc reverts (see ChatScreenConfig).
    var configEditingImage = false
    /// The configured MCP servers (with their approval modes), for the `/mcp` overview. The tool
    /// details come from the live agent; this carries the per-server transport/auth/approval.
    let mcpServers: [MCPServerConfig]
    /// Each server's connect result (tool count or the error that kept it from loading), so `/mcp`
    /// can flag a server that failed instead of a blank "0 tools". A `var` because a `/mcp` sign-in
    /// refreshes it.
    var mcpStatuses: [MCPServerStatus]
    /// The live MCP layer, when running under the REPL: lets `/mcp` sign an OAuth server in and load
    /// its tools without a restart. Nil in tests / non-REPL construction (sign-in is then disabled).
    let mcpRuntime: MCPRuntime?
    /// The MCP server whose `/mcp` browser sign-in is currently in flight, or nil.
    var mcpLoginServer: String?
    var plannerName: String

    var messages: [Message] = []
    var input: [Character] = []
    var cursor = 0
    var pendingBytes: [UInt8] = [] // incomplete UTF-8 from recent keystrokes
    var history: [String] = []
    var historyIndex: Int? // nil = editing fresh; else an index into `history`
    var draft: [Character] = [] // in-progress input saved while browsing history
    var running = false // a turn is generating
    var loading = false // switching model
    var compacting = false // a manual `/compact` is summarizing the conversation
    var quit = false
    var rows = 24
    var cols = 80
    var contextChars = 0
    /// The live session identity: its id is the agent `threadId`, which keys the file-backed session
    /// store (`~/.ripple/sessions/<id>`). `/fresh` mints a new id here (a new resumable session); a
    /// `/model` switch or `/config` rebuild keeps it, so the conversation carries across.
    let sessionContext: SessionContext
    var threadId: String { sessionContext.id }
    var scrollOffset = 0 // lines hidden below the viewport (0 = following the bottom)
    var totalLines = 0
    var lastTotalLines = 0 // to pin a scrolled-up view as new lines stream in below it
    var contentHeight = 1

    // Status-bar context percentage + a throttled git snapshot (branch / dirty / ahead-behind).
    var sessionTokens = 0 // approx tokens used this session (drives the context percentage)
    var liveAssistant: Assistant? // the in-flight turn, for the live tokens/sec readout
    var gitInfo: String?
    var gitCheckedAt: Date?
    var gitRefreshing = false
    var clickMap: [Int: ClickAction] = [:] // screen row -> action, rebuilt each render
    var resizeSource: (any DispatchSourceSignal)?

    // Render coalescing: handlers call `requestRender()`, which renders at most ~60fps and folds a
    // burst of state changes (a multi-byte mouse packet, fast wheel scrolling, a stream of tokens)
    // into one frame instead of redrawing per event. A pending trailing render catches the last state.
    var renderPending = false
    var lastRenderNanos: UInt64 = 0

    // Transcript line cache: each message's rendered lines keyed by its index, at the width they were
    // built for. Only the live (streaming) message is rebuilt each frame; the rest are reused, so a
    // long session doesn't re-wrap the whole transcript every redraw. Invalidated on resize, a toggle,
    // and clear / fresh.
    var lineCache: [Int: (width: Int, lines: [Line])] = [:]

    // Running turn + the spinner that animates while busy.
    var currentTurn: Task<Void, Never>?
    var turnStart: Date?
    var spinnerTask: Task<Void, Never>?
    var spinnerFrame = 0
    static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    // One-shot launch animation: the "ripple" wordmark in the empty-state banner shimmers in over a
    // handful of frames, then settles. Only runs while the banner is on screen (no messages yet).
    var introTask: Task<Void, Never>?
    var introFrame = 0

    // The unified `/model` overlay (Select / Local / Remote tabs). When set, it owns the screen; its
    // Local / Remote tabs drive `toolsBrowser`, the Select tab its own row editor (see ChatScreenModelHub).
    var modelHub: ModelHub?
    /// True while typing a numeric idle timeout in the Select tab's idle field (keystrokes fall through
    /// to the shared input buffer); mirrors `configEditingImage` for the container image.
    var modelEditingIdle = false

    // An in-progress model download (from the `/model` Local tab or a model switch), shown as a
    // progress bar above the input box; the task is cancellable with esc.
    var downloading: DownloadProgress?
    var downloadTask: Task<Void, Never>?

    // `/config` settings editor overlay (capabilities on/off + sandbox mode).
    var config: ConfigEditor?

    // `/tools` browser overlay (toolsets, then a toolset's tool details). `toolsScrollTop` pins the
    // next render to the top, so opening a (possibly long) toolset starts at its first tool.
    var toolsBrowser: ToolsBrowser?
    var toolsScrollTop = false
    /// First visible group (index into `groups`) of a browser list, so a long list scrolls while its
    /// header and footer stay pinned. Kept across renders for stable scrolling; reset to 0 when a list
    /// is (re)opened (via `toolsScrollTop`).
    var browserBodyOffset = 0

    // The `/models-config` OpenRouter tab (Tab toggles to it from the local pane). The free-model catalog is
    // fetched once per session and cached; `openRouterFetch` is the in-flight fetch, `openRouterError`
    // the last failure (shown in the empty pane).
    var openRouterCatalog: [OpenRouterModel]?
    var openRouterFetch: Task<Void, Never>?
    var openRouterError: String?
    /// The OpenRouter tab's live filter query (matched against each model's provider + id + name);
    /// typed while the tab is open to narrow the list. Empty = show all.
    var openRouterFilter = ""
    /// The provider the OpenRouter tab is drilled into (its human label, e.g. "NVIDIA"), or nil while
    /// showing the top-level provider list. Models are grouped by provider; selecting one drills in.
    var openRouterProvider: String?

    // Help overlay (keys + commands); dismissed by any key.
    var help = false

    // The current plan (the agent's todo list), shown as a single panel pinned just above the input
    // box and updated in place as the agent revises it - never re-printed into the transcript. Set
    // from `.todosUpdated` events during a turn, cleared when the next user message is submitted.
    // `planCollapsed` folds the panel to its titled bar (click the header to toggle).
    var plan: [TodoItem] = []
    var planCollapsed = false

    // Human-in-the-loop tool approvals. `gate.pending` is the call awaiting a decision; the user
    // picks Approve (0), Reject (1), or Always allow this tool (2). The shell card omits "always
    // allow" (2 choices) and defaults the selection to Reject.
    let gate: ApprovalGate
    var approvalSelection = 0
    /// The call the selection was last seeded for, so a re-render doesn't clobber navigation.
    var lastApprovalID: UUID?
    /// The shell approval whose command the user is editing in the input box (nil otherwise). While
    /// set, the input is editable and Enter resolves the call with the edited command.
    var editingApproval: ToolApprovalRequest?
    // Permission mode (Tab cycles it), a session allowlist of tools to auto-approve, and the
    // one-step arming for the loud "accept all" (YOLO) mode.
    var permissionMode: PermissionMode = .ask
    var allowlist: Set<String> = []
    var pendingYolo = false

    // Agent-initiated questions (the `ask_user` tool). `askGate.pending` holds the questions awaiting
    // answers; the card shows one question per tab, each multiple-choice carrying an "Other" free-text
    // row. The form state (see ChatScreenAskUser) is seeded when a request arrives and reset on resolve.
    let askGate: AskUserGate
    var askUserTab = 0 // the active question (tab)
    var askUserChoice = 0 // the highlighted choice row in the active multiple-choice question
    var askUserAnswers: [String] = [] // collected answers, one per question
    var askUserSelected: [Set<Int>] = [] // checked choice indices per question (multi_select only)
    var askUserOther: [String] = [] // the free-text "Other" value per question (multi_select only)
    var askUserEditing = false // typing a free-text answer in the input box (text question / "Other")
    var lastAskUserID: UUID? // the request the form state was last seeded for
    /// Where the caret sits inside the ask_user card while typing an answer: a card-relative row index
    /// (offset from the card's top row) and an absolute screen column. Nil when not typing. Set by
    /// `askUserLines`, read by `render()`.
    var askUserCursorCell: (row: Int, col: Int)?

    // Escape / CSI parsing.
    var pendingEsc = false
    var inCSI = false
    var csi: [UInt8] = []
    var pasting = false // inside a bracketed paste (ESC[200~ .. ESC[201~)

    var busy: Bool { running || loading || compacting }

    /// A full-screen menu (the unified `/model` overlay, the `/tools` / `/mcp` browser, the `/config`
    /// editor, or `/help`) owns the screen: the renderer hides the input box, status line, and plan panel
    /// and gives that height to the menu. Distinct from `menuActive` (the `/` command palette, which sits
    /// above a still-visible input box).
    var inMenu: Bool { help || config != nil || toolsBrowser != nil || modelHub != nil }

    /// A slash command shown in the `/` palette.
    struct Command { let name: String; let description: String }
    static let commands = [
        Command(name: "/model", description: "choose & manage models (main agent, vision, local, remote)"),
        Command(name: "/tools", description: "list the agent's tools by toolset"),
        Command(name: "/mcp", description: "list MCP servers, their tools and approval"),
        Command(name: "/config", description: "edit capabilities, sandbox & logging"),
        Command(name: "/compact", description: "summarize older turns to free up the context window"),
        Command(name: "/help", description: "show keys and commands"),
        Command(name: "/fresh", description: "start a new conversation"),
        Command(name: "/clear", description: "clear the screen"),
        Command(name: "/exit", description: "quit")
    ]

    // The `/` command palette selection (see ChatScreenInput for the matches/active computeds).
    var menuIndex = 0

    // @file mention picker: a fuzzy match over the working directory for the `@token` at the cursor
    // (see ChatScreenEditing for the token/match computeds and the scan).
    var fileMenuIndex = 0
    var cwdFiles: [String]? // scanned once per session

    init(
        variant: DeepAgentVariant, agent: ReactAgent, build: @escaping Build, gate: ApprovalGate,
        askGate: AskUserGate = AskUserGate(),
        variants: [DeepAgentVariant] = DeepAgentVariant.all,
        mcpServers: [MCPServerConfig] = [], mcpStatuses: [MCPServerStatus] = [],
        mcpRuntime: MCPRuntime? = nil, policy: AgentToolPolicy = .init(), workingDirectory: URL? = nil,
        sessionContext: SessionContext = SessionContext(id: UUID().uuidString),
        instructionFiles: [String] = [],
        modelLoadStatus: @escaping @MainActor () -> String? = { nil }
    ) {
        self.modelLoadStatus = modelLoadStatus
        self.variant = variant
        self.variants = variants
        self.agent = agent
        self.build = build
        self.gate = gate
        self.askGate = askGate
        self.mcpServers = mcpServers
        self.mcpStatuses = mcpStatuses
        self.mcpRuntime = mcpRuntime
        self.policy = policy
        self.workingDirectory = workingDirectory
        self.sessionContext = sessionContext
        self.instructionFiles = instructionFiles
        logMessages = workingDirectory.map { RippleAgentConfig.loadLogMessages(workingDirectory: $0) } ?? false
        prefixKVCache = workingDirectory.map { RippleAgentConfig.loadPrefixKVCache(workingDirectory: $0) } ?? true
        PrefixKVStore.isEnabledOverride = prefixKVCache
        sandboxEverEnabled = policy.sandbox.isEnabled
        plannerName = Self.name(variant.textModelID)
    }

    func run() async {
        sync()
        Terminal.enter()
        resizeSource = Terminal.onResize { [weak self] in Task { @MainActor in self?.sync(render: true) } }
        gate.onChange = { [weak self] in self?.seedApprovalSelection(); self?.requestRender() } // off the key loop
        gate.policy = { [weak self] request in self?.autoDecision(for: request) } // permission mode / allowlist
        askGate.onChange = { [weak self] in self?.seedAskUserState(); self?.render() } // ask_user form, off the key loop
        render()
        startIntro()
        // Process a whole input batch (one terminal read - typically a complete keystroke or mouse
        // packet) before requesting a single frame, so a multi-byte sequence or a fast wheel burst
        // costs one coalesced render, not one per byte.
        for await batch in Terminal.keyStream() {
            for key in batch {
                handle(key)
                if quit { break }
            }
            if quit { break }
            requestRender()
        }
        introTask?.cancel()
        spinnerTask?.cancel()
        resizeSource?.cancel()
        Terminal.leave()
    }

    func sync(render renderNow: Bool = false) {
        let size = Terminal.size()
        if size.cols != cols { lineCache.removeAll() } // a width change invalidates every cached row
        rows = size.rows
        cols = size.cols
        if renderNow { requestRender() }
    }

    // MARK: - Scrollbar chrome

    /// The transcript scrollbar geometry (its right-margin column, the thumb's top row offset and
    /// length), or nil when the content fits. ``drawScrollingContent`` draws each cell inline with its
    /// content row - right after the row's erase-to-end-of-line - so the bar is never wiped by one
    /// pass and repainted by a later one (which flashes on terminals without atomic synchronized
    /// updates). It sits one column into the right margin so it never shares a cell with a box border.
    func scrollbarThumb(width: Int) -> (column: Int, top: Int, thumb: Int)? {
        guard totalLines > contentHeight, contentHeight > 1 else { return nil }
        let thumb = max(1, contentHeight * contentHeight / totalLines)
        let scrollable = totalLines - contentHeight
        let firstVisible = max(0, totalLines - scrollOffset - contentHeight) // top visible line index
        let top = scrollable > 0 ? (contentHeight - thumb) * firstVisible / scrollable : 0
        return (width + 3, top, thumb)
    }

    /// One scrollbar cell for content-row `offset` (drawn at `row`), or "" when there is no bar.
    func scrollbarCell(_ bar: (column: Int, top: Int, thumb: Int)?, row: Int, offset: Int) -> String {
        guard let bar else { return "" }
        let inThumb = offset >= bar.top && offset < bar.top + bar.thumb
        return "\u{1B}[\(row);\(bar.column)H" + (inThumb ? Paint.fg(244, "┃") : Paint.fg(238, "│"))
    }

    /// The active scroll viewport - the rows the scrolling window actually shows. A boxed menu loses
    /// its top + bottom borders and the title pad row; the transcript (and the browser group list,
    /// which scrolls itself) use the full content height. Used by both the scroll-offset clamp and
    /// ``scroll(by:)`` so scrolling can always reach the last row.
    var scrollViewport: Int {
        let isBrowserList = toolsBrowser != nil && toolsBrowser?.openGroup == nil
        return (inMenu && !isBrowserList) ? max(1, panelBodyHeight(contentHeight)) : contentHeight
    }

    /// When scrolled up, overlay the bottom content row with a clickable "more below" nudge.
    func scrollNudge(width: Int) -> String {
        guard scrollOffset > 0 else { return "" }
        let row = 1 + contentHeight
        let label = " ▼ \(scrollOffset) more below - End to jump "
        let clipped = String(label.prefix(max(0, width - 2)))
        clickMap[row] = .jumpToLatest
        return place(row, "  " + Paint.bgFg(236, 250, clipped))
    }

    var inputText: String { String(input) }

    /// The input is composing a bang command - `!cmd` runs in the container, `!!cmd` in the local
    /// shell - which restyles the input box so it's clear Enter will run a command, not message the
    /// agent. Suppressed while editing a shell-approval command (that has its own overlay).
    var bangMode: BangCommand.Target? {
        guard editingApproval == nil, inputText.hasPrefix("!") else { return nil }
        return inputText.hasPrefix("!!") ? .local : .container
    }

    /// The input box's border + prompt color: green for a local-shell bang, blue for a container
    /// bang, the usual dim gray otherwise.
    var inputAccent: Int {
        switch bangMode {
        case .local: 114
        case .container: 75
        case nil: 238
        }
    }

    // MARK: - Render

    func render() {
        clickMap.removeAll()
        let width = cols - 4 // fill the terminal width (a 2-column margin each side)
        let bottomPad = 1 // a blank row under the status line so it isn't flush against the edge
        let messageGap = 1 // a blank row between the transcript and the input box, for breathing room
        let inner = width - 4
        let textWidth = max(4, inner - 2)

        // The input lays out into visual rows (honoring newlines and soft-wrapping by display width)
        // and the box grows downward, capped; its height shapes the content area. The visible window
        // follows the cursor line.
        let layout = layoutInput(input, width: textWidth, cursor: cursor)
        let allInputRows = layout.rows
        let maxInputRows = min(6, max(1, rows / 3))
        let cursorLine = layout.line
        var windowStart = max(0, allInputRows.count - maxInputRows)
        if cursorLine < windowStart { windowStart = cursorLine }
        if cursorLine >= windowStart + maxInputRows { windowStart = cursorLine - maxInputRows + 1 }
        let inputRows = Array(allInputRows[windowStart ..< min(allInputRows.count, windowStart + maxInputRows)])
        let inputCount = inputRows.count
        // A full-screen menu (picker / browser / config / help) owns the keyboard: hide the input box,
        // status line, plan panel, and overlays, and give all of that height to the menu.
        let menu = inMenu
        // While an `ask_user` prompt is up (and not in a menu), its card *is* the bottom region - the
        // answer is typed on a line inside the card's border, so it's a single widget rather than a card
        // stacked over a separate input box.
        let askUserCard: [Line] = menu ? [] : (askGate.pending.map { askUserLines($0, width: width) } ?? [])
        let usingAskUserCard = !askUserCard.isEmpty
        // The block pinned just above the bottom region, tallest first: the plan panel, then a
        // pending-approval card / the working indicator / the `/` command palette (those are mutually
        // exclusive). Empty in a menu, and the overlay is also empty under an ask_user card (which
        // subsumes it).
        let overlay = (menu || usingAskUserCard) ? [] : overlayLines(width: width)
        let planPanel = menu ? [] : planPanelLines(width: width)
        let aboveInput = planPanel + overlay
        // The bottom region: the ask_user card, else the input box (its rows plus the two borders).
        let bottomCount = usingAskUserCard ? askUserCard.count : inputCount + 2
        let bottomTop = rows - bottomPad - bottomCount // first row of the bottom region
        contentHeight = menu
            ? max(1, rows - 1 - bottomPad)
            : max(1, rows - 2 - bottomPad - messageGap - aboveInput.count - bottomCount)

        // A browser group list (openGroup == nil) is drawn with a pinned header + footer, scrolling
        // only the rows between them; the detail view and every other overlay use the generic
        // scrolling `lines` window.
        let isBrowserList = toolsBrowser != nil && toolsBrowser?.openGroup == nil
        var lines: [Line]
        if help {
            lines = helpLines(width: width)
        } else if let editor = config {
            lines = configLines(editor, width: width)
        } else if let hub = modelHub, hub.tab == .select {
            lines = modelSelectLines(hub.select, width: width) // Local / Remote tabs use `drawBrowserList`
        } else if isBrowserList {
            lines = [] // drawn by `drawBrowserList`
        } else if let browser = toolsBrowser {
            lines = toolsLines(browser, width: width)
        } else {
            lines = messageLines(width: width)
        }
        while lines.last?.text == "" { lines.removeLast() } // don't waste the viewport on trailing blanks
        totalLines = lines.count
        // The scroll clamp uses the active viewport (``scrollViewport``) - a boxed menu is shorter than
        // the content area (its borders + title pad) - or the last rows stay unreachable.
        let viewport = scrollViewport
        // Pin a scrolled-up view to the same content as new lines stream in below it (no drift).
        if scrollOffset > 0, totalLines > lastTotalLines { scrollOffset += totalLines - lastTotalLines }
        lastTotalLines = totalLines
        scrollOffset = min(scrollOffset, max(0, totalLines - viewport))
        // A freshly opened `/tools` level starts at the top (its detail may overflow the viewport).
        // The pinned-list path consumes `toolsScrollTop` itself (resetting its body scroll), so skip it.
        if toolsScrollTop, !isBrowserList { scrollOffset = max(0, totalLines - viewport); toolsScrollTop = false }

        // Wrap the whole frame in a synchronized update (DECSET 2026) and draw with the cursor
        // hidden: the terminal buffers every row and presents them in one shot, so there is no
        // tearing and the cursor never ghosts across the redrawn rows as they paint (most visible
        // during fast mouse-wheel scrolling). Terminals that don't support 2026 ignore it and still
        // benefit from the cursor being hidden during the draw. Closed (cursor shown + 2026 off) at
        // the end of the frame.
        var frame = "\u{1B}[?2026h\u{1B}[?25l\u{1B}[H" + place(1, "")
        if let browser = toolsBrowser, isBrowserList {
            frame += drawBrowserList(browser, width: width, top: 2) // boxed: title/tabs + scrolled rows + footer
        } else if menu {
            frame += drawMenuPanel(lines, width: width, top: 2) // boxed picker / config / help / tool detail
        } else {
            frame += drawScrollingContent(lines, width: width)
        }
        if menu {
            // The menu fills the screen down to the bottom padding; no input box / status / plan panel.
            for row in (2 + contentHeight) ... rows { frame += place(row, "") }
        } else {
            for gap in 0 ..< messageGap { frame += place(2 + contentHeight + gap, "") } // breathing room

            // Plan panel + overlay block (above), then the bottom region - the ask_user card (which
            // owns the input itself) when one is up, else the normal input box - then the status line,
            // pinned just above the bottom padding.
            for (index, line) in aboveInput.enumerated() {
                let row = bottomTop - aboveInput.count + index
                frame += place(row, line.text)
                if let action = line.action { clickMap[row] = action }
            }
            frame += drawBottomRegion(width: width, bottomTop: bottomTop, askUserCard: askUserCard, inputRows: inputRows)
            frame += place(rows - bottomPad, statusLine(width: width))
            for row in (rows - bottomPad + 1) ... rows { frame += place(row, "") } // bottom padding rows
        }

        // Cursor: on the ask_user card it sits on the embedded answer line while typing (else hidden);
        // otherwise at the input box's edit position whenever it's editable - including over an empty
        // box, where it rests on the first dimmed placeholder character. Move first, then show -
        // otherwise a terminal that ignores DECSET 2026 reveals the cursor at the previous draw position
        // for a frame and it visibly jumps.
        frame += cursorEscape(
            usingAskUserCard: usingAskUserCard, bottomTop: bottomTop,
            cursorLine: cursorLine, windowStart: windowStart, col: layout.col
        )
        frame += "\u{1B}[?2026l" // end the synchronized update - present the whole frame atomically
        Terminal.write(frame)
    }

    /// Draw the bottom region just above the status line: the ask_user card (which owns the input
    /// itself) when one is up, else the normal input box. Registers any row click actions.
    private func drawBottomRegion(width: Int, bottomTop: Int, askUserCard: [Line], inputRows: [String]) -> String {
        let inner = width - 4
        var frame = ""
        if !askUserCard.isEmpty {
            for (index, line) in askUserCard.enumerated() {
                let row = bottomTop + index
                frame += place(row, line.text)
                if let action = line.action { clickMap[row] = action }
            }
            return frame
        }
        frame += place(bottomTop, inputBoxTop(width: width))
        for (index, text) in inputRows.enumerated() {
            frame += place(bottomTop + 1 + index, inputRow(text, first: index == 0, inner: inner))
        }
        frame += place(bottomTop + 1 + inputRows.count, inputBoxBottom(width: width)) // just below the input rows
        return frame
    }

    /// The cursor escape for the end of the frame: on the ask_user card it sits on the embedded answer
    /// line while typing (else hidden - the card owns the keys); otherwise at the input box's edit
    /// position whenever it's editable. Move first, then show (see the render() note).
    private func cursorEscape(
        usingAskUserCard: Bool, bottomTop: Int, cursorLine: Int, windowStart: Int, col: Int
    ) -> String {
        if usingAskUserCard {
            guard let cell = askUserCursorCell else { return "\u{1B}[?25l" }
            return "\u{1B}[\(bottomTop + cell.row);\(cell.col)H\u{1B}[?25h"
        }
        guard editable else { return "\u{1B}[?25l" }
        return "\u{1B}[\(bottomTop + 1 + (cursorLine - windowStart));\(7 + col)H\u{1B}[?25h"
    }

    /// Request a frame instead of drawing one directly. Renders immediately when the last frame was
    /// over a frame-time ago, else schedules a single trailing render - so a burst of state changes (a
    /// multi-byte mouse packet, fast wheel scrolling, a stream of tokens) coalesces into at most ~60
    /// frames a second rather than one full redraw per event. The trailing render always catches the
    /// latest state.
    func requestRender() {
        guard !quit else { return }
        let frameNanos: UInt64 = 1_000_000_000 / 60
        let now = DispatchTime.now().uptimeNanoseconds
        if lastRenderNanos == 0 || now &- lastRenderNanos >= frameNanos {
            lastRenderNanos = now
            render()
            return
        }
        guard !renderPending else { return }
        renderPending = true
        let remaining = frameNanos - (now &- lastRenderNanos)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .nanoseconds(Int(remaining)))
            guard let self, !quit else { return }
            renderPending = false
            lastRenderNanos = DispatchTime.now().uptimeNanoseconds
            render()
        }
    }

    func inputRow(_ text: String, first: Bool, inner: Int) -> String {
        let accent = inputAccent
        // The prompt arrow takes the bang accent so it reads as part of the restyled box.
        let prefix = first ? (bangMode != nil ? Paint.fg(accent, "❯") : Paint.arrow("❯")) + " " : "  "
        let shown: String
        let used: Int
        if first, inputText.isEmpty {
            let placeholder = busy ? "Type your next message (sends when ready)…" : "Ask anything…"
            shown = Paint.fg(240, placeholder)
            used = TextWidth.of(placeholder)
        } else {
            shown = highlightInput(text)
            used = TextWidth.of(text)
        }
        let pad = String(repeating: " ", count: max(0, inner - 2 - used))
        return "  " + Paint.fg(accent, "│") + " " + prefix + shown + pad + " " + Paint.fg(accent, "│")
    }

    /// The top border of the input box. In bang mode it's tinted (blue container / green local
    /// shell) and carries the target as a label riding the border ("╭─ container ─...─╮"), so the
    /// box itself signals that Enter runs a command rather than messaging the agent.
    func inputBoxTop(width: Int) -> String {
        let accent = inputAccent
        guard let mode = bangMode else {
            return "  " + Paint.fg(accent, "╭" + String(repeating: "─", count: width - 2) + "╮")
        }
        let label = mode == .local ? "local shell" : "container"
        let fill = max(0, (width - 2) - (TextWidth.of(label) + 3)) // "─ " + label + " "
        return "  " + Paint.fg(accent, "╭─ " + label + " " + String(repeating: "─", count: fill) + "╮")
    }

    func inputBoxBottom(width: Int) -> String {
        "  " + Paint.fg(inputAccent, "╰" + String(repeating: "─", count: width - 2) + "╯")
    }

    func place(_ row: Int, _ content: String) -> String {
        "\u{1B}[\(row);1H" + content + "\u{1B}[K"
    }

    /// Draw the content area as a single scrolling window of `lines` (the transcript, help, config,
    /// picker, and the browser detail view). The browser group list takes the pinned-header path in
    /// ``drawBrowserList(_:width:top:)`` instead.
    private func drawScrollingContent(_ lines: [Line], width: Int) -> String {
        let visible: [Line] = lines.count <= contentHeight
            ? lines
            : Array(lines[(lines.count - scrollOffset - contentHeight) ..< (lines.count - scrollOffset)])
        let bar = scrollbarThumb(width: width)
        var out = ""
        for offset in 0 ..< contentHeight {
            let row = 2 + offset
            if offset < visible.count {
                out += place(row, visible[offset].text)
                if let action = visible[offset].action { clickMap[row] = action }
            } else {
                out += place(row, "")
            }
            out += scrollbarCell(bar, row: row, offset: offset) // inline, right after the row's clear
        }
        out += scrollNudge(width: width) // "N more below" when scrolled up - it erases the bottom row's bar
        if scrollOffset > 0 { out += scrollbarCell(bar, row: 1 + contentHeight, offset: contentHeight - 1) }
        return out
    }
}
