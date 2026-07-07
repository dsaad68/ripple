import DeepAgents
import DeepAgentsMLX
import Foundation

// The unified `/model` overlay for `ripple chat`: one command with three tabs (switched with ←/→ or
// Tab) - **Select** (choose the deep agent's main agent + vision, local or remote, and their idle
// timeouts), **Local** (download / remove the on-device MLX models), and **Remote** (browse and add
// free OpenRouter models). It folds together what used to be `/model`, the `/config` Models tab, and
// `/models-config`. The Local and Remote tabs reuse the existing ``ToolsBrowser`` panes
// (``makeModelsBrowser`` / ``showOpenRouterTab``); the Select tab is the row editor below.

/// The `/model` overlay's three tabs and the Select-tab editor state. The Local / Remote tabs are
/// backed by ``ChatScreen/toolsBrowser`` (set up on the tab switch), so the hub only needs to carry
/// the active tab and the Select editor.
struct ModelHub {
    enum Tab: CaseIterable {
        case select, local, remote
        var title: String {
            switch self {
            case .select: "Select"
            case .local: "Local"
            case .remote: "Remote"
            }
        }
    }

    var tab: Tab = .select
    var select: ModelSelectEditor
}

/// The Select tab: pick the deep agent's main agent + vision model (each a downloaded local model or
/// a registered remote one) and their idle timeouts. A working copy applied + persisted when the hub
/// closes (see ``ChatScreen/applyModelSelect(_:)``) - a main-agent change routes through the
/// `/model`-switch path, a vision/idle change rebuilds in place.
struct ModelSelectEditor {
    /// One row on the Select tab.
    struct Row {
        let id: String
        let displayName: String
        let summary: String
        var isMainAgent: Bool { id == ModelSelectEditor.mainAgentRowID }
        var isVision: Bool { id == ModelSelectEditor.visionRowID }
        var isModelSelect: Bool { isMainAgent || isVision }
        var isIdle: Bool { id == ModelSelectEditor.mainIdleRowID || id == ModelSelectEditor.visionIdleRowID }
    }

    /// An open multiple-choice model picker (the Main agent / Vision rows): ↑↓ move `index`, Enter
    /// commits the choice, Esc cancels.
    struct ModelPick {
        enum Field { case mainAgent, vision }
        /// One choosable model. `id == ""` is the vision "Off" option.
        struct Option { let id: String; let label: String }
        let field: Field
        let options: [Option]
        var index: Int
        var current: Option? { options.indices.contains(index) ? options[index] : nil }
    }

    static let mainAgentRowID = "deepMain"
    static let visionRowID = "deepVision"
    static let mainIdleRowID = "mainIdle"
    static let visionIdleRowID = "visionIdle"

    var index = 0
    /// The open multiple-choice model picker, when the user is choosing a model.
    var picking: ModelPick?

    /// Working copies of the deep agent model + idle-timeout settings (Ripple settings). `mainAgentID` is
    /// also the live `/model` selection; `visionID == ""` turns the vision subagent off; idle minutes of
    /// `0` keep a model resident.
    var mainAgentID: String
    var visionID: String
    var mainAgentIdleMinutes: Int
    var visionIdleMinutes: Int

    /// The registered remote (OpenAI-compatible) models, so a main agent / vision can be a remote model
    /// too. Refreshed when the Select tab is (re)entered, so a model added on the Remote tab shows here.
    var remote: [OpenAIModelConfig]

    /// The settings as the editor opened, so ``ChatScreen/applyModelSelect(_:)`` persists + applies only
    /// what changed (a main-agent change routes through the model-switch path).
    let initialMainAgent: String
    let initialVision: String
    let initialMainIdle: Int
    let initialVisionIdle: Int

    init(
        mainAgent: String, vision: String,
        mainAgentIdleMinutes: Int, visionIdleMinutes: Int, remote: [OpenAIModelConfig]
    ) {
        mainAgentID = mainAgent
        visionID = vision
        self.mainAgentIdleMinutes = mainAgentIdleMinutes
        self.visionIdleMinutes = visionIdleMinutes
        self.remote = remote
        initialMainAgent = mainAgent
        initialVision = vision
        initialMainIdle = mainAgentIdleMinutes
        initialVisionIdle = visionIdleMinutes
    }

    var mainAgentChanged: Bool { mainAgentID != initialMainAgent }
    var visionChanged: Bool { visionID != initialVision }
    var idleChanged: Bool { mainAgentIdleMinutes != initialMainIdle || visionIdleMinutes != initialVisionIdle }

    var rows: [Row] {
        [
            Row(
                id: Self.mainAgentRowID, displayName: "Main agent",
                summary: "The local or remote language model that plans the task and delegates subtasks. "
                    + "Press space to choose from the downloaded and registered models."
            ),
            Row(
                id: Self.visionRowID, displayName: "Vision",
                summary: "The vision model the vision subagent runs - it loads only when the main agent "
                    + "looks at the screen, then idle-unloads. Space to choose; \"Off\" drops vision."
            ),
            Row(
                id: Self.mainIdleRowID, displayName: "Main agent idle",
                summary: "Minutes the main agent may sit idle before it's unloaded from memory (it "
                    + "reloads on the next turn). Press e to type a value; 0 keeps it resident."
            ),
            Row(
                id: Self.visionIdleRowID, displayName: "Vision idle",
                summary: "Minutes the vision model may sit idle before it's unloaded. Press e to type "
                    + "a value; 0 keeps it resident."
            )
        ]
    }

    var current: Row? { rows.indices.contains(index) ? rows[index] : nil }

    mutating func move(_ delta: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        index = (index + delta + rows.count) % rows.count
    }

    // MARK: - Multiple-choice model picker

    /// The Main agent picker options: the downloaded language models (plus the current one, so switching
    /// is instant and never triggers a silent multi-GB download) followed by every registered remote model.
    var mainAgentOptions: [String] {
        var ids = MlxModel.languageCatalog.filter { MlxModelLoader.isDownloadedOnDisk($0.id) }.map(\.id)
        ids += remote.map(\.name)
        if !ids.contains(mainAgentID) { ids.insert(mainAgentID, at: 0) }
        return ids
    }

    /// The Vision picker options: "Off" first, then the downloaded vision models (plus the current one)
    /// and the registered remote models that support vision.
    var visionOptions: [String] {
        var ids = MlxModel.catalog.filter { $0.acceptsImages && MlxModelLoader.isDownloadedOnDisk($0.id) }.map(\.id)
        ids += remote.filter(\.vision).map(\.name)
        if !visionID.isEmpty, !ids.contains(visionID) { ids.insert(visionID, at: 0) }
        return [""] + ids
    }

    /// Open the multiple-choice picker for the highlighted model row (no-op off a model row).
    mutating func beginPicking() {
        guard let row = current else { return }
        if row.isMainAgent {
            let opts = mainAgentOptions.map { ModelPick.Option(id: $0, label: modelLabel($0)) }
            picking = ModelPick(field: .mainAgent, options: opts, index: opts.firstIndex { $0.id == mainAgentID } ?? 0)
        } else if row.isVision {
            let opts = visionOptions.map { ModelPick.Option(id: $0, label: $0.isEmpty ? "Off" : modelLabel($0)) }
            picking = ModelPick(field: .vision, options: opts, index: opts.firstIndex { $0.id == visionID } ?? 0)
        }
    }

    mutating func movePicking(_ delta: Int) {
        guard var pick = picking, !pick.options.isEmpty else { return }
        pick.index = (pick.index + delta + pick.options.count) % pick.options.count
        picking = pick
    }

    /// Apply the highlighted picker option to its field and close the picker.
    mutating func commitPicking() {
        if let pick = picking, let option = pick.current {
            switch pick.field {
            case .mainAgent: mainAgentID = option.id
            case .vision: visionID = option.id
            }
        }
        picking = nil
    }

    mutating func cancelPicking() { picking = nil }

    // MARK: - Idle timeouts

    /// The highlighted idle row's current minutes, or nil if the highlighted row isn't an idle row.
    func currentIdleMinutes() -> Int? {
        guard let row = current else { return nil }
        if row.id == Self.mainIdleRowID { return mainAgentIdleMinutes }
        if row.id == Self.visionIdleRowID { return visionIdleMinutes }
        return nil
    }

    /// Set the highlighted idle row's minutes (clamped to >= 0). No-op off an idle row.
    mutating func setCurrentIdleMinutes(_ minutes: Int) {
        guard let row = current else { return }
        if row.id == Self.mainIdleRowID {
            mainAgentIdleMinutes = max(0, minutes)
        } else if row.id == Self.visionIdleRowID {
            visionIdleMinutes = max(0, minutes)
        }
    }

    // MARK: - Display

    /// Is `row` "active" (coloured on vs off)? The main agent is always on; vision is on unless "Off";
    /// an idle row is on unless it keeps the model resident (0).
    func isOn(_ row: Row) -> Bool {
        if row.isMainAgent { return true }
        if row.isVision { return !visionID.isEmpty }
        if row.id == Self.mainIdleRowID { return mainAgentIdleMinutes > 0 }
        if row.id == Self.visionIdleRowID { return visionIdleMinutes > 0 }
        return false
    }

    /// The state label shown on the right of a row.
    func stateLabel(_ row: Row) -> String {
        if row.isMainAgent { return displayName(mainAgentID) }
        if row.isVision { return visionID.isEmpty ? "off" : displayName(visionID) }
        if row.id == Self.mainIdleRowID { return Self.idleLabel(mainAgentIdleMinutes) }
        if row.id == Self.visionIdleRowID { return Self.idleLabel(visionIdleMinutes) }
        return ""
    }

    /// A choosable model's label: a catalog model's short name + detail, a remote model tagged "remote",
    /// else the raw id.
    func modelLabel(_ id: String) -> String {
        if let model = MlxModel.catalog.first(where: { $0.id == id }) { return "\(model.shortName)  \(model.detail)" }
        if remote.contains(where: { $0.name == id }) { return "\(id)  remote" }
        return id
    }

    /// A compact name for the row's right-hand state: a catalog short name, else the id (a remote /
    /// custom model name).
    func displayName(_ id: String) -> String {
        MlxModel.catalog.first { $0.id == id }?.shortName ?? id
    }

    static func shortName(_ id: String) -> String {
        MlxModel.catalog.first { $0.id == id }?.shortName ?? id
    }

    static func idleLabel(_ minutes: Int) -> String {
        minutes <= 0 ? "resident" : "\(minutes) min"
    }
}

extension ChatScreen {
    // MARK: - Open / switch / close

    /// Open the unified `/model` overlay on `tab` (the Select tab by default), seeding the Select editor
    /// from the live planner + the project's vision / idle settings.
    func openModelHub(tab: ModelHub.Tab = .select) {
        modelHub = ModelHub(tab: .select, select: makeModelSelectEditor())
        modelEditingIdle = false
        setHubTab(tab)
    }

    /// Build the Select-tab editor: the main agent is the live `/model` selection; the vision model and
    /// idle timeouts come from `settings.json` (project then `~/.ripple`), defaulting to the variant's
    /// vision and 10 minutes; the remote list is loaded so a remote model can back either role.
    func makeModelSelectEditor() -> ModelSelectEditor {
        let remote = RippleModelConfig.loadModels(workingDirectory: modelsWorkingDirectory)
        let vision: String
        let mainIdle: Int
        let visionIdle: Int
        if let workingDirectory {
            vision = RippleAgentConfig.loadVisionModel(workingDirectory: workingDirectory) ?? variant.visionModelID
            mainIdle = RippleAgentConfig.loadPlannerIdleMinutes(workingDirectory: workingDirectory)
            visionIdle = RippleAgentConfig.loadVisionIdleMinutes(workingDirectory: workingDirectory)
        } else {
            vision = variant.visionModelID
            mainIdle = RippleAgentConfig.defaultIdleMinutes
            visionIdle = RippleAgentConfig.defaultIdleMinutes
        }
        return ModelSelectEditor(
            mainAgent: variant.textModelID, vision: vision,
            mainAgentIdleMinutes: mainIdle, visionIdleMinutes: visionIdle, remote: remote
        )
    }

    /// Make `tab` the active hub tab, wiring up the backing pane: the Local tab builds the on-device
    /// model browser, the Remote tab opens the OpenRouter pane (fetching once), and the Select tab clears
    /// the browser and refreshes its remote-model list (so a just-added remote model is selectable).
    func setHubTab(_ tab: ModelHub.Tab) {
        guard modelHub != nil else { return }
        modelHub?.tab = tab
        modelEditingIdle = false
        switch tab {
        case .select:
            toolsBrowser = nil
            modelHub?.select.remote = RippleModelConfig.loadModels(workingDirectory: modelsWorkingDirectory)
        case .local:
            toolsBrowser = makeModelsBrowser()
            toolsScrollTop = true
        case .remote:
            showOpenRouterTab()
        }
        requestRender()
    }

    /// Move to the next / previous hub tab (←/→ or Tab). Ignored while a model picker or the idle field
    /// owns the keyboard.
    func switchModelHubTab(_ delta: Int) {
        guard let hub = modelHub, hub.select.picking == nil, !modelEditingIdle else { return }
        let all = ModelHub.Tab.allCases
        guard let i = all.firstIndex(of: hub.tab) else { return }
        setHubTab(all[(i + delta + all.count) % all.count])
    }

    /// Esc inside the hub: back out of an open model picker / idle field / OpenRouter filter or drill-in
    /// first, otherwise close the hub (applying any pending Select changes).
    func escapeModelHub() {
        guard let hub = modelHub else { return }
        switch hub.tab {
        case .select:
            if modelHub?.select.picking != nil {
                modelHub?.select.cancelPicking()
            } else if modelEditingIdle {
                cancelModelIdleEdit()
            } else {
                closeModelHub()
            }
        case .local:
            closeModelHub()
        case .remote:
            if !openRouterFilter.isEmpty {
                openRouterFilter = ""
                refreshOpenRouterBrowser(keeping: 0)
            } else if openRouterProvider != nil {
                backToOpenRouterProviders()
            } else {
                closeModelHub()
            }
        }
    }

    /// Close the hub and apply the Select tab's pending changes (Local / Remote edits already took effect
    /// live). Stops any in-flight OpenRouter fetch and clears the backing browser.
    func closeModelHub() {
        let editor = modelHub?.select
        openRouterFetch?.cancel()
        openRouterFetch = nil
        toolsBrowser = nil
        modelHub = nil
        modelEditingIdle = false
        if let editor { applyModelSelect(editor) }
    }

    /// Persist + apply the Select tab's changes: a changed main agent routes through the model-switch
    /// path (rebuild + persist `selectedModel`); a changed vision / idle persists and rebuilds in place.
    func applyModelSelect(_ editor: ModelSelectEditor) {
        if let workingDirectory {
            if editor.visionChanged {
                try? RippleAgentConfig.saveVisionModel(editor.visionID, workingDirectory: workingDirectory)
            }
            if editor.mainAgentIdleMinutes != editor.initialMainIdle {
                try? RippleAgentConfig.savePlannerIdleMinutes(editor.mainAgentIdleMinutes, workingDirectory: workingDirectory)
            }
            if editor.visionIdleMinutes != editor.initialVisionIdle {
                try? RippleAgentConfig.saveVisionIdleMinutes(editor.visionIdleMinutes, workingDirectory: workingDirectory)
            }
        }
        // Only switch when the chosen main agent is still selectable - a model removed on the Local /
        // Remote tab after it was picked on Select leaves the live planner untouched rather than
        // synthesizing a bogus variant (remote) or cold-downloading on the next turn (local). A
        // vision / idle change still rebuilds the current planner.
        if editor.mainAgentChanged, mainAgentSelectable(editor.mainAgentID) {
            switchToVariant(modelSelectVariant(for: editor.mainAgentID))
            return
        }
        guard editor.visionChanged || editor.idleChanged else { return }
        rebuildAgent()
    }

    /// Whether a chosen main-agent id can be switched to without a surprise: a currently-registered
    /// remote model, or a local model that's actually downloaded (re-read live, not from the Select
    /// editor's possibly-stale snapshot).
    func mainAgentSelectable(_ id: String) -> Bool {
        let remote = RippleModelConfig.loadModels(workingDirectory: modelsWorkingDirectory)
        return remote.contains { $0.name == id } || MlxModelLoader.isDownloadedOnDisk(id)
    }

    /// The variant to switch to for a chosen main-agent id: a known variant whose model matches (a
    /// remote model's variant, or an on-device preset), else a synthesized local variant carrying that
    /// model (its vision / idle come from settings at build time).
    func modelSelectVariant(for id: String) -> DeepAgentVariant {
        if let match = variants.first(where: { $0.textModelID == id }) { return match }
        return DeepAgentVariant(
            id: id, label: ModelSelectEditor.shortName(id), detail: "custom main agent",
            textModelID: id, visionModelID: variant.visionModelID
        )
    }

    // MARK: - Select-tab input

    /// Keys while the Select tab is active (mirrors ``handleConfigByte``): a model picker owns the
    /// keyboard while open (enter / space selects); otherwise space opens the picker / starts an idle
    /// edit, e edits an idle row, enter / ctrl-c save & close, ctrl-d quits.
    func handleModelSelectByte(_ byte: UInt8) {
        if modelHub?.select.picking != nil {
            switch byte {
            case 0x0D, 0x0A, 0x20: modelHub?.select.commitPicking()
            case 0x03: closeModelHub()
            case 0x04: quit = true
            default: break
            }
            return
        }
        switch byte {
        case 0x0D, 0x0A: closeModelHub() // enter: save & close
        case 0x20: activateModelSelectRow() // space: open the model picker / edit an idle row
        case 0x65 where modelHub?.select.current?.isIdle == true: beginModelIdleEdit() // 'e': type an idle timeout
        case 0x03: closeModelHub() // ctrl-c closes the hub (doesn't quit)
        case 0x04: quit = true // ctrl-d
        default: break
        }
    }

    /// Space on the highlighted Select row: open the multiple-choice picker for a model row, else begin
    /// numeric entry for an idle row.
    private func activateModelSelectRow() {
        guard let row = modelHub?.select.current else { return }
        if row.isModelSelect {
            modelHub?.select.beginPicking()
        } else if row.isIdle {
            beginModelIdleEdit()
        }
    }

    /// Begin typing a numeric idle timeout on the highlighted Main agent / Vision idle row: load the
    /// current value into the shared input buffer. Keystrokes then fall through to it until Enter
    /// commits or Esc reverts.
    func beginModelIdleEdit() {
        guard modelHub?.select.current?.isIdle == true else { return }
        modelEditingIdle = true
        setInput(String(modelHub?.select.currentIdleMinutes() ?? 0))
    }

    /// Commit the typed minutes into the working settings (blank or non-numeric reads as 0 = resident).
    func commitModelIdleEdit() {
        let minutes = max(0, Int(inputText.trimmingCharacters(in: .whitespaces)) ?? 0)
        modelHub?.select.setCurrentIdleMinutes(minutes)
        modelEditingIdle = false
        clearInput()
    }

    /// Abandon the idle edit, leaving the working settings untouched.
    func cancelModelIdleEdit() {
        modelEditingIdle = false
        clearInput()
    }

    // MARK: - Rendering

    /// The Select-tab body: the model + idle rows, each with its state and (when highlighted) its
    /// summary; the Idle-timeouts subsection set off by a horizontal rule. A model picker replaces the
    /// rows while open. The tab strip + key hints ride the panel border (see ``menuChrome``).
    func modelSelectLines(_ editor: ModelSelectEditor, width: Int) -> [Line] {
        if let pick = editor.picking { return modelPickLines(pick) }
        var out: [Line] = []
        for (index, row) in editor.rows.enumerated() {
            if row.id == ModelSelectEditor.mainIdleRowID {
                out.append(Line(""))
                out.append(Line("  " + Paint.fg(240, String(repeating: "─", count: max(10, width - 8)))))
                out.append(Line("  " + Paint.fg(245, "Idle timeouts")
                        + Paint.fg(238, "  minutes before an unused model is freed (0 = keep loaded)")))
                out.append(Line(""))
            }
            let selected = index == editor.index
            let on = editor.isOn(row)
            let marker = selected ? Paint.arrow("❯") : " "
            let nameColor = selected ? 252 : 245
            let stateColor = on ? 114 : 174
            let pad = String(repeating: " ", count: max(2, 17 - row.displayName.count))
            let line = "\(marker) " + Paint.fg(nameColor, row.displayName)
                + pad + Paint.fg(stateColor, editor.stateLabel(row))
            out.append(Line(line, nil, highlight: selected))
            if selected {
                for wrapped in wrap(row.summary, width - 10) { out.append(Line("    " + Paint.fg(240, wrapped))) }
                if row.isIdle { out.append(contentsOf: modelIdleEditLines(editor, row: row)) }
            }
        }
        return out
    }

    /// The multiple-choice model picker shown in place of the Select rows while choosing a Main agent /
    /// Vision model.
    private func modelPickLines(_ pick: ModelSelectEditor.ModelPick) -> [Line] {
        let title = pick.field == .mainAgent ? "Select main agent model" : "Select vision model"
        var out: [Line] = [Line("  " + Paint.fg(252, title)), Line("")]
        for (index, option) in pick.options.enumerated() {
            let selected = index == pick.index
            let marker = selected ? Paint.arrow("❯") : " "
            out.append(Line("\(marker) " + Paint.fg(selected ? 252 : 245, option.label), nil, highlight: selected))
        }
        return out
    }

    /// The line(s) under the highlighted Main agent / Vision idle row: the editable minutes field with a
    /// block caret while typing (Esc reverts, Enter commits), otherwise the edit-key hint.
    private func modelIdleEditLines(_ editor: ModelSelectEditor, row: ModelSelectEditor.Row) -> [Line] {
        guard modelEditingIdle, editor.current?.id == row.id else {
            return [Line("    " + Paint.fg(240, "e edit · 0 keeps it loaded"))]
        }
        return [
            Line("    " + Paint.fg(252, "minutes: " + inputText) + Paint.bgFg(250, 236, " ")),
            Line("    " + Paint.fg(240, "enter save · esc cancel"))
        ]
    }

    /// The three-tab strip riding the `/model` overlay's top border (on every tab): the active tab a
    /// filled chip in the heading purple (on the soft selection background), the others dim plain text.
    func modelHubTabStrip(_ active: ModelHub.Tab) -> String {
        ModelHub.Tab.allCases.map { tab in
            tab == active
                ? Paint.bgFg(Theme.userBg.xterm, Theme.agent.xterm, " " + tab.title + " ")
                : Paint.fg(245, " " + tab.title + " ")
        }.joined(separator: " ")
    }
}
