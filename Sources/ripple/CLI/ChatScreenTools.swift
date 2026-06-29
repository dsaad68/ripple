import DeepAgents
import Foundation

// The `/tools` browser: builds the toolset groups from the live agent and renders both levels
// (the group list and a single toolset's tool details). Split out of ChatScreen to keep that
// file within budget; the model types live in ChatScreenModel.

extension ChatScreen {
    /// Build the browser from the current agent: one group per tool-contributing middleware (the
    /// "toolset"), plus the agent's own base tools if it has any. A tool's `gated` flag comes from
    /// the human-in-the-loop policy, so the browser shows exactly which calls ask for approval.
    func makeToolsBrowser() -> ToolsBrowser {
        let gated = agent.middleware.compactMap { $0 as? HumanInTheLoopMiddleware }.first?.interruptOn ?? [:]

        var groups: [ToolsBrowser.Group] = []
        if !agent.tools.isEmpty {
            groups.append(ToolsBrowser.Group(title: "Agent tools", tools: agent.tools.map { toolInfo($0, gated: gated) }))
        }
        for middleware in agent.middleware where !middleware.tools.isEmpty {
            groups.append(ToolsBrowser.Group(
                title: Self.toolsetTitle(middleware.name),
                tools: middleware.tools.map { toolInfo($0, gated: gated) }
            ))
        }
        return ToolsBrowser(groups: groups)
    }

    /// Build the `/mcp` overview: one group per configured MCP server, subtitled with its
    /// transport, auth, and approval mode, listing the tools that server contributes (matched by
    /// the namespaced `server__tool` dispatch prefix). The tool details come from the live agent.
    func makeMCPBrowser() -> ToolsBrowser {
        let gated = agent.middleware.compactMap { $0 as? HumanInTheLoopMiddleware }.first?.interruptOn ?? [:]
        let mcpTools = agent.middleware.first { $0.name == "mcp" }?.tools ?? []

        let statusByName = Dictionary(mcpStatuses.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let groups: [ToolsBrowser.Group] = mcpServers.map { server in
            let prefix = MCPTool.dispatchPrefix(forServer: server.name)
            let tools = mcpTools.filter { $0.name.hasPrefix(prefix) }.map { toolInfo($0, gated: gated) }
            var bits = [server.kind == .http ? "HTTP" : "stdio"]
            if server.kind == .http { bits.append(server.auth == .oauth ? "OAuth" : "Headers") }
            bits.append("approval: \(server.approvalMode.label)")
            // Surface this server's live state: signing in, an OAuth server that needs (or has) a
            // sign-in, or a failure - so it doesn't read as a healthy server with no tools. The
            // not-authenticated nudge is yellow (the renderer dims the rest).
            let status = statusByName[server.name]
            // Drive the auth hints off the runtime's view of the server (OAuth-declared, or a plain HTTP
            // server whose 401 we discovered / that already holds a token) rather than the `oauth` flag,
            // so a `{"type":"http","url":...}` entry with no `oauth` key still invites sign-in.
            let authState = mcpRuntime?.authState(server) ?? .notApplicable
            if server.name == mcpLoginServer {
                bits.append("signing in…")
            } else if authState == .needsAuth {
                bits.append(Paint.fg(179, "⚠ not authenticated - press r to sign in"))
            } else if authState == .signedIn {
                bits.append("signed in · r re-auth · x log out")
            } else if let status, !status.connected {
                bits.append(Paint.fg(179, "⚠ " + (status.error ?? "unavailable")))
            }
            return ToolsBrowser.Group(title: server.name, subtitle: bits.joined(separator: "  ·  "), tools: tools)
        }

        var browser = ToolsBrowser(groups: groups)
        browser.title = "MCP servers"
        browser.isMCP = true
        browser.emptyMessage = "No MCP servers configured. Add one in .ripple/mcp.json."
        return browser
    }

    /// The server the `/mcp` browser would sign in if Enter (or a click) landed on the highlighted
    /// row: that group's server, when it needs a sign-in (a declared OAuth server with no token, or a
    /// plain HTTP server whose auth we discovered from a 401) and a live ``mcpRuntime`` can drive it.
    /// Nil otherwise, so Enter then opens the group as usual.
    func mcpLoginTarget(_ browser: ToolsBrowser) -> MCPServerConfig? {
        guard let server = mcpAuthCapableSelection(browser), let runtime = mcpRuntime,
              runtime.authState(server) == .needsAuth else { return nil }
        return server
    }

    /// The server highlighted in the `/mcp` list when it can sign in at all - a declared OAuth server,
    /// or any HTTP server that answered a 401 or already holds a token. These are the rows where the
    /// `r` (re-auth) / `x` (log out) keys and footer hint apply; nil inside an opened group's tool
    /// detail (where those keys don't), for a non-MCP browser, or without a live ``mcpRuntime``.
    func mcpAuthCapableSelection(_ browser: ToolsBrowser) -> MCPServerConfig? {
        guard browser.isMCP, browser.openGroup == nil, let runtime = mcpRuntime,
              browser.groups.indices.contains(browser.groupIndex) else { return nil }
        let name = browser.groups[browser.groupIndex].title
        guard let server = mcpServers.first(where: { $0.name == name }),
              runtime.authState(server) != .notApplicable else { return nil }
        return server
    }

    /// Sign `server` in via the browser OAuth flow from the `/mcp` browser, then load its tools live:
    /// refresh the statuses, rebuild the agent so the new tools are callable this session, and
    /// refresh the open browser. A no-op without a live ``mcpRuntime``, or while another sign-in or a
    /// turn is in flight.
    func startMCPLogin(_ server: MCPServerConfig, force: Bool = false) {
        guard let runtime = mcpRuntime, mcpLoginServer == nil, !busy else { return }
        mcpLoginServer = server.name
        if toolsBrowser != nil { toolsBrowser = makeMCPBrowser() } // reflect "signing in…"
        requestRender()
        Task {
            let status = await runtime.login(server, force: force)
            mcpLoginServer = nil
            mcpStatuses = runtime.statuses
            if status.connected { await rebuildAgentNow() } // make the now-authed server's tools callable
            if toolsBrowser != nil { toolsBrowser = makeMCPBrowser() }
            requestRender()
        }
    }

    /// Log `server` out from the `/mcp` browser: clear its token, drop its tools from the live agent
    /// (via a rebuild), and refresh the browser.
    func startMCPLogout(_ server: MCPServerConfig) {
        guard let runtime = mcpRuntime, mcpLoginServer == nil, !busy else { return }
        Task {
            await runtime.logout(server)
            mcpStatuses = runtime.statuses
            await rebuildAgentNow()
            if toolsBrowser != nil { toolsBrowser = makeMCPBrowser() }
            requestRender()
        }
    }

    /// Project a tool into the browser's display model: name, whether it's gated (needs approval),
    /// description, and its parameters with type/role labels.
    private func toolInfo(_ tool: any AgentTool, gated: [String: InterruptOnConfig]) -> ToolsBrowser.ToolInfo {
        ToolsBrowser.ToolInfo(
            name: tool.name,
            gated: gated[tool.name] != nil,
            description: tool.description,
            params: tool.parameters.map { param in
                let role = param.isRequired ? "required" : "optional"
                var detail = param.description
                if let allowed = param.extraProperties["enum"] as? [String], !allowed.isEmpty {
                    if !detail.isEmpty, !detail.hasSuffix(" ") { detail += " " }
                    detail += "One of: \(allowed.joined(separator: ", "))."
                }
                return ToolsBrowser.Param(
                    label: "\(param.name) (\(role), \(Self.typeLabel(param.type)))", detail: detail
                )
            }
        )
    }

    /// A human-friendly toolset name for a middleware's machine name.
    nonisolated static func toolsetTitle(_ name: String) -> String {
        switch name {
        case "todo_list": "Planning"
        case "filesystem": "Filesystem"
        case "subagents": "Subagents"
        case "screenshot": "Screen Capture"
        case "clipboard": "Clipboard"
        case "apple_notes": "Apple Notes"
        case "utility": "Utility"
        default: name.split(separator: "_").map(\.capitalized).joined(separator: " ")
        }
    }

    /// A short label for a parameter's JSON-schema type.
    nonisolated static func typeLabel(_ type: ToolParameterType) -> String {
        switch type {
        case .string: "string"
        case .bool: "bool"
        case .int: "int"
        case .double: "number"
        case .data: "data"
        case .array: "array"
        case .object: "object"
        }
    }

    // MARK: - Rendering

    /// The browser content for the *detail* level (one toolset's tools). The group list is drawn
    /// separately with a pinned header/footer - see ``drawBrowserList(_:width:top:)``.
    func toolsLines(_ browser: ToolsBrowser, width: Int) -> [Line] {
        guard let group = browser.current else { return [] }
        return toolGroupDetailLines(group, width: width)
    }

    // MARK: - Menu panel framing

    /// Rows of chrome between a panel's title border and its first body row: a blank gutter so the
    /// title gets breathing room instead of sitting flush against the content. The body that callers
    /// window must fit ``panelBodyHeight(_:)`` (height minus the two borders and this pad).
    static let panelTitlePad = 1

    /// How many body rows a boxed menu of `height` rows can show: minus the top border, the title
    /// pad, and the bottom border.
    func panelBodyHeight(_ height: Int) -> Int { max(0, height - 2 - Self.panelTitlePad) }

    /// Frame a full-screen menu in a light box from row `top` spanning `height` rows: `chrome.title`
    /// (which may itself be a tab strip) rides the top border, a blank pad row sits under it, the
    /// `body` rows are framed as "│ … │" (padded / filled to the inner height, truncated so they never
    /// overflow, a `highlight` row painted as a selection band), and `chrome.footer` rides the bottom
    /// border. Registers clickable body rows in `clickMap`. A caller that overflows its body lays a
    /// scrollbar over the body region with ``panelScrollbar`` after this. Same equal-width invariant
    /// as ``ChatScreen/card(width:title:trailing:rows:edge:titleAction:)``.
    func drawPanel(width: Int, top: Int, height: Int, chrome: (title: String, footer: String), body: [Line]) -> String {
        let edge = Theme.border.xterm
        let inner = width - 4 // visible columns between "│ " and " │"
        let bodyHeight = panelBodyHeight(height)
        let bodyTop = top + 1 + Self.panelTitlePad // the blank pad sits between the title and the body
        func framedRow(_ text: String, highlight: Bool = false) -> String {
            let pad = String(repeating: " ", count: max(0, inner - TextWidth.of(text)))
            let content = " " + text + pad + " " // the full inner span between the side borders
            let painted = highlight ? Paint.onBackground(content, Theme.userBg) : content
            return "  " + Paint.fg(edge, "│") + painted + Paint.fg(edge, "│")
        }

        let topFill = max(0, width - 5 - TextWidth.of(chrome.title)) // "╭─ " + title + " " + fill + "╮"
        var out = place(top, "  " + Paint.fg(edge, "╭─ ") + chrome.title
            + Paint.fg(edge, " " + String(repeating: "─", count: topFill) + "╮"))
        out += place(top + 1, framedRow("")) // breathing room under the title

        for offset in 0 ..< bodyHeight {
            let row = bodyTop + offset
            if offset < body.count {
                out += place(row, framedRow(TextWidth.truncate(body[offset].text, to: inner),
                                            highlight: body[offset].highlight))
                if let action = body[offset].action { clickMap[row] = action }
            } else {
                out += place(row, framedRow(""))
            }
        }

        let bottom: String
        if chrome.footer.isEmpty {
            bottom = "  " + Paint.fg(edge, "╰" + String(repeating: "─", count: width - 2) + "╯")
        } else {
            let fill = max(0, width - 5 - TextWidth.of(chrome.footer)) // "╰─ " + footer + " " + fill + "╯"
            bottom = "  " + Paint.fg(edge, "╰─ ") + chrome.footer
                + Paint.fg(edge, " " + String(repeating: "─", count: fill) + "╯")
        }
        out += place(top + height - 1, bottom)
        return out
    }

    /// Window `lines` to the boxed menu's inner height, frame them with ``drawPanel``, and lay a
    /// scrollbar over the body when it overflows. The chrome comes from ``menuChrome()`` for whichever
    /// menu owns the screen.
    func drawMenuPanel(_ lines: [Line], width: Int, top: Int) -> String {
        let height = contentHeight
        let bodyHeight = max(1, panelBodyHeight(height))
        let total = lines.count
        let offset = min(scrollOffset, max(0, total - bodyHeight))
        let visible: [Line] = total <= bodyHeight
            ? lines
            : Array(lines[(total - offset - bodyHeight) ..< (total - offset)])
        var out = drawPanel(width: width, top: top, height: height, chrome: menuChrome(), body: visible)
        if total > bodyHeight {
            out += panelScrollbar(width: width, top: top + 1 + Self.panelTitlePad, height: bodyHeight,
                                  scroll: (total: total, first: total - offset - bodyHeight, shown: bodyHeight))
        }
        return out
    }

    /// A panel's heading: the agent purple, lightly bold, so the title reads as a heading on the box's
    /// top border (it ties into the `◆`/`◇` purple used for thoughts and the plan).
    func panelTitle(_ text: String) -> String { Paint.bold(Paint.fg(Theme.agent.xterm, text)) }

    /// Color a footer hint as key → action pairs: the key tokens (arrows, enter, esc, tab, single
    /// letters) brighter than their dim descriptions, with faint `·` separators - so a long hint line
    /// scans at a glance instead of reading as one gray run. Colors are ``Theme`` roles (dim / faint /
    /// border) so they hold up on truecolor as well as 256-color terminals.
    static func footerHint(_ raw: String) -> String {
        let keys: Set = ["↑↓", "↑", "↓", "←→", "enter", "esc", "tab", "space", "e", "r", "x", "⇄", "enter/esc"]
        return raw.split(separator: " ", omittingEmptySubsequences: false).map { token in
            let part = String(token)
            if part == "·" { return Paint.fg(Theme.border.xterm, part) }
            return keys.contains(part) ? Paint.fg(Theme.dim.xterm, part) : Paint.fg(Theme.faint.xterm, part)
        }.joined(separator: " ")
    }

    /// The border chrome (styled title, footer hint) for the active generic menu - the `/help` sheet,
    /// the `/config` editor, a `/tools`-`/mcp` detail view, or the `/model` picker. The browser group
    /// list supplies its own chrome inside ``drawBrowserList(_:width:top:)``.
    private func menuChrome() -> (title: String, footer: String) {
        if help {
            return (panelTitle("Keys & commands"), Self.footerHint("press any key to close"))
        }
        if let hub = modelHub, hub.tab == .select {
            let editor = hub.select
            let footer: String
            if editor.picking != nil {
                footer = "↑↓ choose · enter select · esc cancel"
            } else if modelEditingIdle {
                footer = "enter save minutes · esc cancel"
            } else if editor.current?.isModelSelect == true {
                footer = "←→ tabs · ↑↓ move · space choose · enter/esc save"
            } else {
                footer = "←→ tabs · ↑↓ move · e edit minutes · enter/esc save"
            }
            return (modelHubTabStrip(.select), Self.footerHint(footer))
        }
        if config != nil {
            let footer: String
            if configEditingImage {
                footer = "enter save image · esc cancel"
            } else if config?.current?.isContainer == true {
                footer = "←→ tabs · ↑↓ move · space cycle · e image · x default · enter/esc save"
            } else {
                footer = "←→ tabs · ↑↓ move · space toggle · enter/esc save & apply"
            }
            return (panelTitle("Settings"), Self.footerHint(footer))
        }
        if let group = toolsBrowser?.current {
            let count = group.tools.count == 1 ? "1 tool" : "\(group.tools.count) tools"
            let title = panelTitle(group.title) + Paint.fg(238, "  ·  ") + Paint.fg(240, count)
            return (title, Self.footerHint("esc to go back"))
        }
        return ("", "")
    }

    /// A right-edge scrollbar over a boxed menu's body region (mirrors ``ChatScreen/scrollbar(width:)``);
    /// the thumb is sized and positioned by `scroll` (total rows, first visible, count shown).
    private func panelScrollbar(width: Int, top: Int, height: Int, scroll: (total: Int, first: Int, shown: Int)) -> String {
        guard scroll.total > scroll.shown, height > 0 else { return "" }
        let column = width + 3
        let thumb = max(1, height * scroll.shown / scroll.total)
        let scrollable = scroll.total - scroll.shown
        let thumbTop = scrollable > 0 ? (height - thumb) * scroll.first / scrollable : 0
        var out = ""
        for row in 0 ..< height {
            let inThumb = row >= thumbTop && row < thumbTop + thumb
            out += "\u{1B}[\(top + row);\(column)H" + (inThumb ? Paint.fg(244, "┃") : Paint.fg(238, "│"))
        }
        return out
    }

    /// Draw a browser group list (`/tools`, `/mcp`, local + OpenRouter `/models-config`) as a boxed
    /// panel from row `top`: the title (the plain name, or the Local ⇄ OpenRouter tab strip) rides the
    /// top border, the key hints ride the bottom border, an optional inner header (filter / banner)
    /// sits at the top of the body, and only the group rows below it scroll - so the chrome stays put
    /// in a long list. Records clickable rows in `clickMap` and draws a scrollbar over the group region.
    func drawBrowserList(_ browser: ToolsBrowser, width: Int, top: Int) -> String {
        let height = contentHeight
        let bodyHeight = max(1, panelBodyHeight(height)) // inside the box's borders + the title pad
        let panel = browserPanelSections(browser, width: width)
        if toolsScrollTop { browserBodyOffset = 0; toolsScrollTop = false }

        // The group rows scroll in the space under the box's inner header (filter / banner rows).
        let groupHeight = max(1, bodyHeight - panel.innerHeader.count)
        let groups = panel.groups
        let selected = min(max(0, browser.groupIndex), max(0, groups.count - 1))
        var first = min(max(0, browserBodyOffset), max(0, groups.count - 1))
        first = min(first, maxFirstGroup(groups, bodyHeight: groupHeight))
        if selected < first {
            first = selected
        } else {
            while first < selected, linesBetween(groups, first, selected) > groupHeight { first += 1 }
        }
        browserBodyOffset = first

        // Take whole groups from `first` until the next would overflow the body (always show one).
        var groupBody: [Line] = []
        var index = first
        while index < groups.count, groupBody.count + groups[index].count <= groupHeight {
            groupBody += groups[index]
            index += 1
        }
        if groupBody.isEmpty, first < groups.count { groupBody = Array(groups[first].prefix(groupHeight)) }

        // Frame chrome + (inner header + group rows), then lay a scrollbar over the group region.
        var out = drawPanel(width: width, top: top, height: height, chrome: panel.chrome,
                            body: panel.innerHeader + groupBody)
        out += panelScrollbar(
            width: width, top: top + 1 + Self.panelTitlePad + panel.innerHeader.count, height: groupHeight,
            scroll: (total: groups.count, first: first, shown: max(1, index - first))
        )
        return out
    }

    /// A bordered filter input for the OpenRouter pane, matching the main input box: a rounded box
    /// spanning the panel's inner width with the `❯` prompt, the live query (its tail when long) or a
    /// placeholder, and a thin cursor (the menu hides the terminal's own). Returned as three body rows.
    func filterFieldBox(width: Int) -> [Line] {
        let fw = max(8, width - 4) // the box spans the panel's inner content width
        let edge = Theme.border.xterm
        let textArea = max(1, fw - 6) // inside "│ ❯ " (4) … " │" (2)
        let plain = openRouterFilter.isEmpty
            ? "type to filter…"
            : String(openRouterFilter.suffix(textArea - 1)) // tail, leaving a column for the cursor
        let shown = String(plain.prefix(textArea))
        let styled = openRouterFilter.isEmpty
            ? Paint.fg(240, shown)
            : Paint.fg(252, shown) + Paint.fg(Theme.accent.xterm, "▏")
        let used = TextWidth.of(shown) + (openRouterFilter.isEmpty ? 0 : 1)
        let pad = String(repeating: " ", count: max(0, textArea - used))
        let rule = String(repeating: "─", count: fw - 2)
        return [
            Line(Paint.fg(edge, "╭" + rule + "╮")),
            Line(Paint.fg(edge, "│") + " " + Paint.arrow("❯") + " " + styled + pad + " " + Paint.fg(edge, "│")),
            Line(Paint.fg(edge, "╰" + rule + "╯"))
        ]
    }

    /// The boxed browser's chrome and rows: the `chrome` (top-border title - the plain name, or the
    /// Local ⇄ OpenRouter tab strip - and the bottom-border footer hint), the inner-header rows (the
    /// OpenRouter filter input box and any banner), and the per-group row blocks (each its row +
    /// optional subtitle). An empty list yields a single message "group".
    private func browserPanelSections(_ browser: ToolsBrowser, width: Int)
        -> (chrome: (title: String, footer: String), innerHeader: [Line], groups: [[Line]]) {
        // The Local / Remote panes live inside the `/model` overlay, so they carry its three-tab strip;
        // a plain `/tools` / `/mcp` browser shows its name.
        let title = modelHub != nil
            ? modelHubTabStrip(modelHub!.tab)
            : panelTitle(browser.title)

        var innerHeader: [Line] = []
        if browser.isOpenRouter {
            // A real bordered filter input (matching the main input box) so the user sees what they
            // typed; the provider / count context sits dim below it.
            let shown = browser.groups.count
            innerHeader += filterFieldBox(width: width)
            let context = openRouterProvider.map { "› \($0)  ·  \(shown) models" } ?? "\(shown) providers"
            innerHeader.append(Line(Paint.fg(240, context)))
        }
        if let banner = browser.banner { innerHeader.append(Line(Paint.fg(179, banner))) }
        if !innerHeader.isEmpty { innerHeader.append(Line("")) } // a blank under the inner header

        let footerText: String
        if browser.isOpenRouter, openRouterProvider != nil {
            footerText = "↑↓ select · type to filter · enter add/remove · esc back"
        } else if browser.isOpenRouter {
            footerText = "←→ tabs · ↑↓ select · type to filter · enter open · esc close"
        } else if browser.isModels {
            footerText = "←→ tabs · ↑↓ select · enter download · x remove · esc close"
        } else if browser.isMCP {
            // Only advertise r/x when the highlighted row is a server that can actually sign in (and
            // we're in the list, not an opened group's tool detail) - `handleMCPBrowserKey` ignores r/x
            // otherwise, so the generic hint would lie. Same predicate as the per-server subtitle above.
            footerText = mcpAuthCapableSelection(browser) != nil
                ? "↑↓ select · enter open · r (re)auth · x log out · esc close"
                : "↑↓ select · enter open · esc close"
        } else {
            footerText = "↑↓ select · enter open · esc close"
        }

        let chrome = (title: title, footer: Self.footerHint(footerText))
        guard !browser.groups.isEmpty else {
            return (chrome, innerHeader, [[Line(Paint.fg(244, browser.emptyMessage))]])
        }
        let labelWidth = browser.groups.map { TextWidth.of($0.title) }.max() ?? 0
        let groups: [[Line]] = browser.groups.enumerated().map { index, group in
            let selected = index == browser.groupIndex
            let marker = selected ? Paint.arrow("❯") : " "
            let pad = String(repeating: " ", count: max(2, labelWidth + 2 - TextWidth.of(group.title)))
            let count = group.tools.count == 1 ? "1 tool" : "\(group.tools.count) tools"
            let right = group.trailing ?? Paint.fg(240, count) // models show size + ✓/○ instead of a count
            let row = "\(marker) " + Paint.fg(selected ? 252 : 245, group.title) + pad + right
            var block: [Line] = [Line(row, .openToolGroup(index), highlight: selected)]
            if let subtitle = group.subtitle {
                // Band the subtitle too (the whole entry highlights), brightening it on the band so it
                // stays legible - the dim border grey would vanish on the selection background.
                let subColor = selected ? Theme.dim.xterm : Theme.border.xterm
                block.append(Line("    " + Paint.fg(subColor, subtitle), .openToolGroup(index), highlight: selected))
            }
            return block
        }
        return (chrome, innerHeader, groups)
    }

    /// The highest first-group index that still fills `bodyHeight` (so scrolling never strands the
    /// last page against blank space).
    private func maxFirstGroup(_ groups: [[Line]], bodyHeight: Int) -> Int {
        var lines = 0
        var maxFirst = 0
        for index in stride(from: groups.count - 1, through: 0, by: -1) {
            lines += groups[index].count
            if lines > bodyHeight { maxFirst = index + 1; break }
            maxFirst = index
        }
        return maxFirst
    }

    /// Total rendered lines of `groups[from...through]` (inclusive).
    private func linesBetween(_ groups: [[Line]], _ from: Int, _ through: Int) -> Int {
        guard from <= through, groups.indices.contains(from), groups.indices.contains(through) else { return 0 }
        return groups[from ... through].reduce(0) { $0 + $1.count }
    }

    /// Level 2 body: one toolset's tools, each with its description and parameters (wrapped to width).
    /// The group title / tool count ride the panel's top border and "esc to go back" its bottom border
    /// (see ``menuChrome()``), so this returns only the body rows.
    private func toolGroupDetailLines(_ group: ToolsBrowser.Group, width: Int) -> [Line] {
        var out: [Line] = []
        if let subtitle = group.subtitle {
            out.append(Line("  " + Paint.fg(238, subtitle)))
        }
        out.append(Line(""))
        let textWidth = max(20, width - 12) // leave room for the box border + the in-row indent
        for tool in group.tools {
            var head = "  " + Paint.fg(114, "●") + " " + Paint.fg(252, tool.name)
            if tool.gated { head += "  " + Paint.fg(Theme.warn.xterm, "[needs approval]") }
            out.append(Line(head))
            for line in Self.wrapPlain(tool.description, width: textWidth) {
                out.append(Line("      " + Paint.fg(244, line)))
            }
            for param in tool.params {
                // Split the param name from its "(role, type)" so the name reads brighter than the type.
                out.append(Line("      " + Self.styledParamLabel(param.label)))
                for line in Self.wrapPlain(param.detail, width: textWidth - 2) {
                    out.append(Line("        " + Paint.fg(240, line)))
                }
            }
            out.append(Line(""))
        }
        return out
    }

    /// Color a param's "name (role, type)" label: the name brighter than its dim parenthetical type,
    /// so a long param list reads as name → type rather than one flat run.
    nonisolated static func styledParamLabel(_ label: String) -> String {
        guard let paren = label.firstIndex(of: "(") else { return Paint.fg(252, label) }
        return Paint.fg(252, String(label[..<paren])) + Paint.fg(240, String(label[paren...]))
    }

    /// Word-wrap plain (unstyled) text to `width` display columns. Long single words are hard-split.
    nonisolated static func wrapPlain(_ text: String, width: Int) -> [String] {
        guard width > 0, !text.isEmpty else { return text.isEmpty ? [] : [text] }
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                var word = String(word)
                while TextWidth.of(word) > width { // a single word longer than the line: hard-split it
                    if !line.isEmpty { lines.append(line); line = "" }
                    let cut = String(word.prefix(width))
                    lines.append(cut)
                    word = String(word.dropFirst(cut.count))
                }
                let candidate = line.isEmpty ? word : line + " " + word
                if TextWidth.of(candidate) > width { lines.append(line); line = word } else { line = candidate }
            }
            lines.append(line)
        }
        return lines
    }
}
