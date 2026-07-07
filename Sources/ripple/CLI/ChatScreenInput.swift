import DeepAgents
import Foundation

// Keyboard + mouse routing for `ripple chat`: the escape/CSI state machine and the per-key
// dispatch that turns a keystroke or click into an action. Split out of ChatScreen to keep that
// file within budget; the model types live in ChatScreenModel.
extension ChatScreen {
    var commandMatches: [Command] {
        let query = inputText.lowercased()
        return Self.commands.filter { $0.name.hasPrefix(query) }
    }

    /// The `/` command palette is shown when the input begins with `/` and matches a command (and the
    /// cursor isn't in an `@file` mention, which gets its own picker).
    var menuActive: Bool {
        modelHub == nil && !busy && !fileMenuActive && inputText.hasPrefix("/") && !commandMatches.isEmpty
    }

    var menuSelection: Int { min(max(0, menuIndex), max(0, commandMatches.count - 1)) }

    // MARK: - Input

    func handle(_ key: Terminal.Key) {
        switch key {
        case .escape: onEscape()
        case .byte(let byte): handleByte(byte)
        }
    }

    /// A lone Escape: deny a pending approval, close the help overlay / picker, stop a running turn,
    /// else clear the input.
    func onEscape() {
        if help {
            help = false
        } else if downloading != nil {
            cancelModelDownload() // stop an in-flight model download (files resume on the next pull)
        } else if pendingYolo {
            pendingYolo = false // disarm the accept-all confirmation
        } else if editingApproval != nil {
            cancelEditingApproval() // back to the approval card, command unchanged
        } else if gate.pending != nil {
            resolveApproval(.reject(message: nil))
        } else if askGate.pending != nil {
            escapeAskUser() // back out of "Other" free text, else cancel the whole prompt
        } else if config != nil {
            if configEditingImage { cancelImageEdit() } // esc reverts the image field, staying in /config
            else { applyConfig() } // esc saves & applies, like enter
        } else if modelHub != nil {
            escapeModelHub() // back out of a picker / idle field / OpenRouter filter, else close the hub
        } else if toolsBrowser != nil {
            if toolsBrowser?.openGroup != nil { toolsBrowser?.openGroup = nil; toolsScrollTop = true } // detail -> list
            else { toolsBrowser = nil } // `/tools` / `/mcp` list -> close
        } else if busy {
            cancelTurn()
        } else {
            clearInput()
        }
    }

    func handleByte(_ byte: UInt8) {
        if help { consumeWhileHelp(byte); return }
        if consumeEscapeByte(byte) { return } // CSI / SS3 / Alt-key handling
        if routeModalByte(byte) { return } // a card / overlay / browser owns the keyboard
        switch byte {
        case 0x03: if busy { cancelTurn() } else { quit = true } // Ctrl-C: stop the turn, else quit
        case 0x04: quit = true // Ctrl-D
        case 0x01: cursorHome() // Ctrl-A
        case 0x05: cursorEnd() // Ctrl-E
        case 0x09: handleTab()
        case 0x0D, 0x0A: onEnter()
        case 0x7F, 0x08: deleteBackward()
        case 0x15: clearInput() // Ctrl-U
        case 0x17: deleteWord() // Ctrl-W
        case 0x20...: insert(byte)
        default: break
        }
    }

    /// Route a byte to whichever card / overlay / browser currently owns the keyboard, returning true
    /// when it consumed the key (so `handleByte` falls through to the normal editing keys otherwise).
    /// Help and the escape-sequence parser are handled before this in `handleByte`.
    private func routeModalByte(_ byte: UInt8) -> Bool {
        // While typing a custom container image, let bytes fall through to the input buffer (insert /
        // backspace / cursor) instead of the editor's row keys - mirrors the ask_user "Other" gate below.
        // While typing into a value field (image / idle), let bytes fall through to the input buffer.
        if config != nil, !configEditingImage { handleConfigByte(byte); return true } // settings editor keys
        if let hub = modelHub, hub.tab == .select, !modelEditingIdle { handleModelSelectByte(byte); return true } // Select tab keys
        if pasting { insertPasted(byte); return true } // paste body is literal; its end marker parsed above
        if gate.pending != nil, editingApproval == nil { handleApprovalByte(byte); return true } // approval card keys
        if askGate.pending != nil, !askUserEditing { handleAskUserByte(byte); return true } // ask_user card keys (not while typing)
        if handleMCPBrowserKey(byte) { return true } // `/mcp` per-server sign-in keys (r / x)
        if handleModelsBrowserKey(byte) { return true } // local `/models-config` remove key (x)
        if handleOpenRouterFilterKey(byte) { return true } // OpenRouter tab: type-to-filter (by provider/name)
        return false
    }

    /// In the `/mcp` browser's server list, `r` (re-)authenticates and `x` logs out the highlighted
    /// server - any that can sign in: a declared OAuth server, or a plain HTTP server whose auth was
    /// discovered from a 401 (or that already holds a token). Returns true when the key was handled
    /// here (so it isn't typed into the input).
    func handleMCPBrowserKey(_ byte: UInt8) -> Bool {
        guard let browser = toolsBrowser, let runtime = mcpRuntime,
              let server = mcpAuthCapableSelection(browser) else { return false }
        switch byte {
        case 0x72: startMCPLogin(server, force: true); return true // 'r' (re-)authenticate
        case 0x78: if runtime.authState(server) == .signedIn { startMCPLogout(server) }; return true // 'x' log out
        default: return false
        }
    }

    /// In the local `/models-config` browser, `x` removes the highlighted model from the local cache (enter,
    /// which downloads it, is handled in ``onEnter``). The OpenRouter pane has no `x` - `x` types into
    /// its filter and enter toggles add/remove. Returns true when the key was handled here.
    func handleModelsBrowserKey(_ byte: UInt8) -> Bool {
        guard let browser = toolsBrowser, browser.isModels,
              browser.groups.indices.contains(browser.groupIndex) else { return false }
        if byte == 0x78 { // 'x' remove (consumed but ignored while a download is in flight)
            if downloading == nil { removeModel(at: browser.groupIndex) }
            return true
        }
        return false
    }

    /// Feed `byte` to the escape-sequence state machine. Returns true if it was consumed (it was
    /// mid-sequence or started one); false if it is an ordinary byte the caller should handle. As a
    /// side effect, Alt-Enter inserts a newline.
    func consumeEscapeByte(_ byte: UInt8) -> Bool {
        if inCSI {
            csi.append(byte)
            if (0x40 ... 0x7E).contains(byte) { dispatchCSI(); inCSI = false; csi = [] }
            return true
        }
        if pendingEsc {
            pendingEsc = false
            if byte == 0x1B { pendingEsc = true; return true } // collapse a double-ESC (iTerm "Esc+")
            if byte == 0x5B || byte == 0x4F { inCSI = true; csi = []; return true } // CSI / SS3
            if byte == 0x0D || byte == 0x0A { insertNewline(); return true } // Alt-Enter inserts a newline
            if byte == 0x62 { cursorWordLeft(); return true } // Alt-b / Option-Left -> previous word
            if byte == 0x66 { cursorWordRight(); return true } // Alt-f / Option-Right -> next word
            return false // ESC + other byte = Alt-modified key; let the caller handle the byte
        }
        if byte == 0x1B { pendingEsc = true; return true }
        return false
    }

    /// While the help overlay is up, any key closes it; a multi-byte escape sequence is consumed whole
    /// first (so its trailing bytes don't leak into the input on the next frame).
    func consumeWhileHelp(_ byte: UInt8) {
        if inCSI {
            csi.append(byte)
            if (0x40 ... 0x7E).contains(byte) { inCSI = false; csi = []; help = false }
            return
        }
        if pendingEsc {
            pendingEsc = false
            if byte == 0x5B || byte == 0x4F { inCSI = true; csi = []; return } // CSI / SS3
            help = false // ESC + other byte = Alt-key; treat as a keypress
            return
        }
        if byte == 0x1B { pendingEsc = true; return }
        help = false
    }

    /// Tab inserts a file mention / completes a command when a palette is open, moves to the next
    /// `/model` tab when the overlay is open, else cycles the permission mode.
    private func handleTab() {
        if askGate.pending != nil {
            moveAskUserTab(1) // Tab moves to the next ask_user question
        } else if fileMenuActive {
            selectFile()
        } else if menuActive {
            setInput(commandMatches[menuSelection].name)
        } else if modelHub != nil {
            switchModelHubTab(1) // next `/model` tab (Select -> Local -> Remote)
        } else {
            cyclePermissionMode(reverse: false)
        }
    }

    // MARK: - CSI dispatch

    /// Act on a completed CSI/SS3 sequence: SGR mouse events, modified arrows (word motion), the plain
    /// arrows and navigation keys, the modifyOtherKeys Shift-Enter, and bracketed-paste markers.
    func dispatchCSI() {
        let seq = String(bytes: csi, encoding: .utf8) ?? "" // CSI bytes are always ASCII
        if seq.hasPrefix("<") { dispatchMouseCSI(seq); return } // SGR mouse: press / wheel / release
        if dispatchModifiedArrow(seq) { return } // Option/Ctrl/Shift + Left/Right -> word motion
        switch seq {
        case "A": onUp()
        case "B": onDown()
        case "C": cursorRight() // →
        case "D": cursorLeft() // ←
        case "H", "1~", "7~": cursorHome()
        case "F", "4~", "8~": cursorEnd()
        case "3~": deleteForward() // Delete
        case "5~": scroll(by: contentHeight - 2) // PageUp
        case "6~": scroll(by: -(contentHeight - 2)) // PageDown
        case "Z": // Shift-Tab
            if askGate.pending != nil { moveAskUserTab(-1) } // previous ask_user question
            else if modelHub != nil { switchModelHubTab(-1) } // previous `/model` tab
            else { cyclePermissionMode(reverse: true) }
        // Shift-Enter inserts a newline (grows the input box) instead of sending. Terminals encode it
        // as xterm modifyOtherKeys `27;2;13~` (enabled in `Terminal.enter`) or the kitty `13;2u`.
        case "27;2;13~", "27;2;10~", "13;2u": insertNewline()
        case "200~": pasting = true // bracketed paste begins
        case "201~": pasting = false // bracketed paste ends
        default: break
        }
    }

    /// An SGR mouse report ("<button;col;rowM" press / "…m" release): the wheel scrolls the
    /// transcript, a left-button press is a click on its row.
    private func dispatchMouseCSI(_ seq: String) {
        let parts = seq.dropFirst().dropLast().split(separator: ";").compactMap { Int($0) }
        let button = parts.first ?? -1
        if button == 64 {
            wheel(up: true)
        } else if button == 65 {
            wheel(up: false)
        } else if button == 0, seq.hasSuffix("M"), parts.count >= 3 {
            handleClick(row: parts[2]) // left-button press
        }
    }

    /// Option/Alt (or Ctrl/Shift) + Left/Right arrive as a modified arrow ("1;<mod>D" / "1;<mod>C");
    /// any modifier moves a whole word. Returns true when the sequence was a modified arrow.
    private func dispatchModifiedArrow(_ seq: String) -> Bool {
        guard seq.hasPrefix("1;"), let final = seq.last else { return false }
        if final == "D" { cursorWordLeft(); return true }
        if final == "C" { cursorWordRight(); return true }
        return false
    }

    func onUp() {
        if gate.pending != nil {
            approvalSelection = (approvalSelection + approvalChoiceCount - 1) % approvalChoiceCount // previous
        } else if askGate.pending != nil {
            moveAskUserChoice(-1)
        } else if config != nil {
            if !configEditingImage { config?.move(-1) } // not while typing the container image
        } else if let hub = modelHub, hub.tab == .select {
            if hub.select.picking != nil { modelHub?.select.movePicking(-1) } // navigate the open model picker
            else if !modelEditingIdle { modelHub?.select.move(-1) } // not while typing an idle value
        } else if let browser = toolsBrowser {
            if browser.openGroup == nil { toolsBrowser?.move(-1) } else { scroll(by: 1) } // list: select; detail: up
        } else if fileMenuActive {
            fileMenuIndex = (fileMenuSelection - 1 + fileMatches.count) % fileMatches.count
        } else if menuActive {
            menuIndex = (menuSelection - 1 + commandMatches.count) % commandMatches.count
        } else if editable, let index = verticalCursorIndex(up: true, width: inputTextWidth) {
            cursor = index // move the caret up a visual line within a multi-line input
        } else {
            historyUp() // on the first line (or single-line / empty): recall the previous prompt
        }
    }

    func onDown() {
        if gate.pending != nil {
            approvalSelection = (approvalSelection + 1) % approvalChoiceCount // next
        } else if askGate.pending != nil {
            moveAskUserChoice(1)
        } else if config != nil {
            if !configEditingImage { config?.move(1) } // not while typing the container image
        } else if let hub = modelHub, hub.tab == .select {
            if hub.select.picking != nil { modelHub?.select.movePicking(1) } // navigate the open model picker
            else if !modelEditingIdle { modelHub?.select.move(1) } // not while typing an idle value
        } else if let browser = toolsBrowser {
            if browser.openGroup == nil { toolsBrowser?.move(1) } else { scroll(by: -1) } // list: select; detail: down
        } else if fileMenuActive {
            fileMenuIndex = (fileMenuSelection + 1) % fileMatches.count
        } else if menuActive {
            menuIndex = (menuSelection + 1) % commandMatches.count
        } else if editable, let index = verticalCursorIndex(up: false, width: inputTextWidth) {
            cursor = index // move the caret down a visual line within a multi-line input
        } else {
            historyDown() // on the last line (or single-line): recall the next prompt
        }
    }

    /// The mouse wheel navigates the picker / command palette when one is up, and otherwise scrolls
    /// the transcript (it must not recall history - that is the keyboard arrows' job).
    func wheel(up: Bool) {
        if let browser = toolsBrowser, browser.openGroup == nil {
            toolsBrowser?.move(up ? -1 : 1) // the group list moves the selection; the detail view scrolls (below)
        } else if menuActive {
            menuIndex = (menuSelection + (up ? -1 : 1) + commandMatches.count) % commandMatches.count
        } else {
            scroll(by: up ? 3 : -3)
        }
    }

    func onEnter() {
        if let request = editingApproval { submitEditedApproval(request); return }
        if askGate.pending != nil { askUserAdvanceOrSubmit(); return } // commit the typed answer, advance / submit
        if config != nil {
            if configEditingImage { commitImageEdit() } // commit the image
            else { applyConfig() } // save & close
            return
        }
        if modelHub != nil {
            if modelEditingIdle { commitModelIdleEdit() } // commit the typed idle minutes
            // other Select-tab enters are handled in `handleModelSelectByte` (via `routeModalByte`)
            if modelHub?.tab == .select { return }
        }
        if let browser = toolsBrowser {
            if browser.isOpenRouter { // level 1: drill into a provider; level 2: add/remove a model
                if browser.groups.indices.contains(browser.groupIndex) {
                    if openRouterProvider == nil {
                        openOpenRouterProvider(at: browser.groupIndex)
                    } else {
                        toggleOpenRouterModel(at: browser.groupIndex)
                    }
                }
            } else if browser.isModels { // download the highlighted model
                if browser.groups.indices.contains(browser.groupIndex) { startModelDownload(at: browser.groupIndex) }
            } else if browser.openGroup == nil { // sign in a not-signed-in MCP server, else open the toolset
                if let server = mcpLoginTarget(browser) {
                    startMCPLogin(server)
                } else if !browser.groups.isEmpty {
                    toolsBrowser?.openGroup = browser.groupIndex
                    toolsScrollTop = true
                }
            }
            return
        }
        if fileMenuActive { selectFile(); return } // accept the highlighted file, don't send yet
        if menuActive { setInput(commandMatches[menuSelection].name) } // run the highlighted command
        submit()
    }

    /// A left-click on `row`: expand/collapse a thought, pick a model, or run a palette command.
    func handleClick(row: Int) {
        switch clickMap[row] {
        // A disclosure toggle changes how a past message renders, so drop its cached rows.
        case .toggleThought(let reasoning): reasoning.expanded.toggle(); invalidateTranscriptCache()
        case .toggleStep(let step): step.expanded.toggle(); invalidateTranscriptCache()
        case .toggleStepThought(let step): step.thinkExpanded.toggle(); invalidateTranscriptCache()
        case .toggleBang(let bang): bang.expanded.toggle(); invalidateTranscriptCache()
        case .togglePlan: planCollapsed.toggle()
        case .openToolGroup(let index):
            openToolGroupClick(index)
        case .runCommand(let index):
            guard index < commandMatches.count else { return }
            setInput(commandMatches[index].name)
            submit()
        case .resolveApproval(let approve):
            resolveApproval(approve ? .approve : .reject(message: nil))
        case .alwaysAllowTool:
            alwaysAllow()
        case .editApproval:
            beginEditingApproval()
        case .selectAskUserChoice(let index):
            selectAskUserChoice(index)
            if askUserOnOther { beginAskUserOther() } // clicking "Other" starts free-text entry
        case .submitAskUser:
            askUserAdvanceOrSubmit()
        case .selectFile(let index):
            fileMenuIndex = index; selectFile()
        case .jumpToLatest:
            scrollToLatest()
        case .none: break
        }
    }

    /// A click on a `/tools` / `/mcp` / `/models-config` group row: drill into an OpenRouter provider or
    /// toggle a model, pull a local model, sign an MCP server in, else open the toolset's detail view.
    private func openToolGroupClick(_ index: Int) {
        guard let browser = toolsBrowser, browser.groups.indices.contains(index) else { return }
        toolsBrowser?.groupIndex = index
        if browser.isOpenRouter { // click a provider to drill in, or a model to add/remove
            if openRouterProvider == nil { openOpenRouterProvider(at: index) } else { toggleOpenRouterModel(at: index) }
            return
        }
        if browser.isModels { startModelDownload(at: index); return } // click a model row to pull it
        if let updated = toolsBrowser, let server = mcpLoginTarget(updated) { startMCPLogin(server); return }
        toolsBrowser?.openGroup = index
        toolsScrollTop = true
    }
}
