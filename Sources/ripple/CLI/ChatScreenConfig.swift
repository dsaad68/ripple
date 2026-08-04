import DeepAgents
import DeepAgentsMLX
import Foundation

// The `/config` settings editor for `ripple chat`: input handling, live-apply, and rendering for the
// overlay that toggles capability middleware on/off and cycles the Apple Container sandbox mode. Kept
// in its own `ChatScreen` extension so the editor's UI lives next to its logic (and off the already
// large ChatScreen / ChatScreenRender bodies).
extension ChatScreen {
    /// Keys while the `/config` editor is open: space toggles the highlighted capability (cycles the
    /// container's sandbox mode), enter / ctrl-c save & apply, ctrl-d quits. Arrows arrive as CSI
    /// sequences and are handled by ``onUp`` / ``onDown``.
    func handleConfigByte(_ byte: UInt8) {
        switch byte {
        case 0x0D, 0x0A: applyConfig() // enter: save & apply
        case 0x20: activateConfigRow() // space: toggle / cycle the capability or sandbox
        case 0x65 where config?.current?.isContainer == true: beginImageEdit() // 'e': edit the container image
        case 0x78 where config?.current?.isContainer == true: config?.policy.sandboxImage = nil // 'x': reset to default
        case 0x03: applyConfig() // ctrl-c closes the editor (doesn't quit)
        case 0x04: quit = true // ctrl-d
        default: break
        }
    }

    /// Space on the highlighted row: toggle / cycle the capability or sandbox.
    private func activateConfigRow() {
        config?.toggle()
    }

    /// Build the `/config` editor seeded with the live policy + developer-log and prefix-cache toggles.
    func makeConfigEditor() -> ConfigEditor {
        ConfigEditor(policy: policy, logMessages: logMessages, prefixKVCache: prefixKVCache)
    }

    /// Begin typing a custom container image on the Container row: load the current override (empty for
    /// the built-in default) into the shared input buffer. Keystrokes now fall through to it (see
    /// ``routeModalByte``) until Enter commits or Esc reverts - mirrors the ask_user "Other" entry.
    func beginImageEdit() {
        guard config?.current?.isContainer == true else { return }
        configEditingImage = true
        setInput(config?.policy.sandboxImage ?? "")
    }

    /// Commit the typed image into the working policy: a blank entry clears the override (so it falls
    /// back to ``AppleContainerSandbox/defaultImage``), any other value is stored verbatim.
    func commitImageEdit() {
        let trimmed = inputText.replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        config?.policy.sandboxImage = trimmed.isEmpty ? nil : trimmed
        configEditingImage = false
        clearInput()
    }

    /// Abandon the image edit, leaving the working policy untouched.
    func cancelImageEdit() {
        configEditingImage = false
        clearInput()
    }

    /// Close the `/config` editor: persist the edited policy and, if it changed, rebuild the agent so
    /// the new capability set takes effect immediately.
    func applyConfig() {
        guard let editor = config else { return }
        config = nil
        configEditingImage = false
        let updated = editor.policy
        let logChanged = editor.logMessages != logMessages
        let prefixChanged = editor.prefixKVCache != prefixKVCache
        let imageChanged = updated.sandboxImage != policy.sandboxImage
        let policyOrLogChanged = updated != policy || logChanged
        policy = updated
        logMessages = editor.logMessages
        prefixKVCache = editor.prefixKVCache
        // The prefix-cache toggle takes effect on the next turn - no agent rebuild needed.
        if prefixChanged { PrefixKVStore.isEnabledOverride = prefixKVCache }
        if updated.sandbox.isEnabled { sandboxEverEnabled = true }
        if let workingDirectory {
            try? RippleAgentConfig.savePolicy(updated, workingDirectory: workingDirectory)
            if logChanged { try? RippleAgentConfig.saveLogMessages(logMessages, workingDirectory: workingDirectory) }
            if prefixChanged { try? RippleAgentConfig.savePrefixKVCache(prefixKVCache, workingDirectory: workingDirectory) }
        }
        guard policyOrLogChanged else { return }
        // A new image only takes effect on a fresh container: the sandbox adopts an existing one by name
        // and ignores the image (see AppleContainerSandbox.ensureContainer), so tear the current one down
        // first - when one may exist and nothing is running in it - before rebuilding the agent.
        if imageChanged, sandboxEverEnabled, !busy, let workingDirectory {
            Task {
                await AppleContainerSandbox.teardown(for: WorkspaceRoot(rootURL: workingDirectory))
                await rebuildAgentNow()
            }
        } else {
            rebuildAgent()
        }
    }

    /// Rebuild the agent for the current planner with the live policy (after a `/config` change),
    /// reusing the warm model containers - the model switch, minus the picker.
    func rebuildAgent() {
        guard !busy else { return }
        Task { await rebuildAgentNow() }
    }

    /// Rebuild the agent for the current planner + policy (reusing the warm model containers) and
    /// await it - so a caller that needs the new agent in place afterwards (a `/mcp` sign-in loading
    /// the now-authed server's tools) can continue once it's swapped in. ``rebuildAgent()`` is the
    /// fire-and-forget wrapper.
    func rebuildAgentNow() async {
        loading = true
        startSpinner()
        requestRender()
        if let newAgent = await build(variant, policy) {
            agent = newAgent
            // Keep the same session across a `/config` rebuild - only the capability set changes.
        }
        loading = false
        requestRender()
    }

    /// The `/config` editor body: a tab strip, then the active tab's rows - each with its on/off (or
    /// sandbox-mode) state and, when highlighted, its summary underneath. (Title + key hints ride the
    /// panel border, see ``menuChrome``.)
    func configLines(_ editor: ConfigEditor, width: Int) -> [Line] {
        var out: [Line] = [tabBar(editor), Line("")]
        for (index, row) in editor.rows.enumerated() {
            let selected = index == editor.index
            let locked = editor.isLocked(row) // shell governed by the sandbox - not user-toggleable
            let on = editor.isOn(row)
            let marker = selected ? Paint.arrow("❯") : " "
            // A governed (locked) row never takes the bright selected-name highlight, and shows a
            // muted green/red on/off (vs the full green/red of a normal, directly-editable row) so it
            // reads as controlled by the sandbox.
            let nameColor = (!locked && selected) ? 252 : 245
            let stateColor = locked
                ? (on ? Theme.mutedSuccess.xterm : Theme.mutedDanger.xterm)
                : (on ? 114 : 174)
            let pad = String(repeating: " ", count: max(2, 17 - row.displayName.count))
            let line = "\(marker) " + Paint.fg(nameColor, row.displayName)
                + pad + Paint.fg(stateColor, editor.stateLabel(row))
            out.append(Line(line, nil, highlight: selected))
            if selected {
                let note = locked ? "Set by the sandbox mode - change it on the Sandbox tab." : row.summary
                for wrapped in wrap(note, width - 10) { out.append(Line("    " + Paint.fg(240, wrapped))) }
                if row.isContainer { out.append(contentsOf: containerImageLines(editor, width: width)) }
            }
        }
        return out
    }

    /// The tab strip atop the `/config` panel: the active tab bold + filled, the others dim. ←/→ switch.
    private func tabBar(_ editor: ConfigEditor) -> Line {
        let parts = ConfigEditor.Tab.allCases.map { tab in
            tab == editor.tab
                ? Paint.bold(Paint.fg(252, "● " + tab.title))
                : Paint.fg(240, "○ " + tab.title)
        }
        return Line("  " + parts.joined(separator: "   "))
    }

    /// The container image under the highlighted Container row, drawn as a titled box: the resolved
    /// image (dimmed, tagged default/custom on the border) when idle, and a typeable field with a block
    /// caret while editing (press e to edit, Enter commits, Esc reverts - see the panel footer for keys).
    /// The caret rides the field's end - a menu overlay has no hardware cursor.
    private func containerImageLines(_ editor: ConfigEditor, width: Int) -> [Line] {
        let edge = Theme.border.xterm
        let inner = max(16, min(width - 12, 60)) // interior columns between the box's │ bars
        // Title on the top border: "image", tagged default/custom when not editing.
        let tag = configEditingImage ? "" : (editor.policy.sandboxImage == nil ? " (default)" : " (custom)")
        let title = "image" + tag
        let titleFill = max(0, inner - TextWidth.of(title) - 3) // "─ " + title + " " then fill to ╮
        let top = "    " + Paint.fg(edge, "╭─ ") + Paint.fg(245, title)
            + Paint.fg(edge, " " + String(repeating: "─", count: titleFill) + "╮")
        let bottom = "    " + Paint.fg(edge, "╰" + String(repeating: "─", count: inner) + "╯")

        // The field interior: typed text + a block caret while editing, else the dimmed resolved image,
        // clipped (with a leading "…") to fit the box.
        let painted: String
        let visibleWidth: Int
        if configEditingImage {
            let avail = inner - 3 // leading space + caret block + trailing space
            let typed = TextWidth.of(inputText) > avail ? "…" + String(inputText.suffix(avail - 1)) : inputText
            painted = Paint.fg(252, typed) + Paint.bgFg(250, 236, " ")
            visibleWidth = TextWidth.of(typed) + 1
        } else {
            let avail = inner - 2 // leading + trailing space
            let image = editor.containerImage
            let shown = TextWidth.of(image) > avail ? "…" + String(image.suffix(avail - 1)) : image
            painted = Paint.fg(240, shown)
            visibleWidth = TextWidth.of(shown)
        }
        let pad = String(repeating: " ", count: max(0, inner - 2 - visibleWidth)) // 2 = leading + trailing space
        let mid = "    " + Paint.fg(edge, "│") + " " + painted + pad + " " + Paint.fg(edge, "│")
        return [Line(top), Line(mid), Line(bottom)]
    }
}
