import DeepAgents
import DeepAgentsMLX
import Foundation

// The `/model` overlay's Local tab - download / remove the on-device MLX models from inside the REPL -
// and the shared in-TUI download flow it drives. It reuses the ``ToolsBrowser`` overlay (the catalog
// laid out as a table, sectioned by model family) and shows a single progress bar above the input box
// while a model downloads. Split out of ChatScreen to keep that file within budget.
/// The Local tab's two top-level groups. A retrieval encoder is not a chat model at all - it has no
/// LM head, and picking one as a planner fails at load - so the tab separates them before anything
/// else, rather than leaving the reader to infer it from a name.
enum LocalModelGroup: CaseIterable {
    case llm, embedding

    var title: String { self == .llm ? "LLM" : "Embedding" }

    /// What the group is for, as the dim tag beside its heading.
    var tag: String { self == .llm ? "chat and vision models" : "retrieval encoders for search_tools" }

    func contains(_ model: MlxModel) -> Bool {
        self == .embedding ? model.kind == .retriever : model.kind != .retriever
    }
}

/// One family row on the Local tab's first level: a model line, within one group, and its rows. The
/// line is what you actually choose between - "the LFM2.5 ones", "the Qwen3.6 ones" - where a
/// precision or a vision variant is a detail you settle after opening it.
struct LocalFamily {
    let group: LocalModelGroup
    let family: MlxModel.Family
    let models: [MlxModel]

    var name: String { family.title }
    /// The stable key the highlighted row is re-found by after a rebuild.
    var key: String { "\(group.title)/\(family.title)" }
}

extension ChatScreen {
    /// The catalog, narrowed by ``modelFilter`` - the source both Local levels are derived from, so a
    /// search narrows the provider list and its drilled-in models alike (as it does on Remote).
    var filteredLocalModels: [MlxModel] {
        MlxModel.catalog.filter { $0.matches(query: modelFilter) }
    }

    /// The Local tab's first level: model families, grouped LLM then Embedding, each group's families
    /// in the order the catalog introduces them.
    var localFamilies: [LocalFamily] {
        LocalModelGroup.allCases.flatMap { group -> [LocalFamily] in
            let models = filteredLocalModels.filter { group.contains($0) }
            var order: [MlxModel.Family] = []
            for model in models where !order.contains(model.family) { order.append(model.family) }
            return order.map { family in
                LocalFamily(group: group, family: family, models: models.filter { $0.family == family })
            }
        }
    }

    /// The models behind the drilled-into family, sectioned by what they are for (Text, then
    /// Text + Vision, then Vision / Embedding) - the Local tab's second level. Empty at the first
    /// level, so the download / remove keys, which index this, are inert on a family row.
    var localModelRows: [MlxModel] {
        localModelSections.flatMap(\.models)
    }

    /// The drilled-into family's models grouped by ``MlxModel/roleLabel``, roles in the order the
    /// family's catalog rows introduce them.
    var localModelSections: [(role: String, models: [MlxModel])] {
        guard let drill = localFamily,
              let family = localFamilies.first(where: { $0.key == drill }) else { return [] }
        var order: [String] = []
        for model in family.models where !order.contains(model.roleLabel) { order.append(model.roleLabel) }
        return order.map { role in (role, family.models.filter { $0.roleLabel == role }) }
    }

    /// Build the Local-tab browser. Level 1 is one row per model family under an **LLM** /
    /// **Embedding** heading, with how many of its models are on disk; level 2 is that family's models
    /// under a heading per role, each a table row - a ✓/○ on-disk marker, the weight format, and the
    /// size / context window / output budget in aligned columns - with the repo id (plus what it is
    /// for, and a "default" note) as the subtitle of whichever row is highlighted. Two levels, drilled
    /// with enter and backed out with esc, exactly like the Remote tab.
    func makeModelsBrowser() -> ToolsBrowser {
        var browser = ToolsBrowser(groups: localFamily == nil ? localFamilyGroups() : localModelGroups())
        browser.title = "Local models"
        browser.isModels = true
        browser.emptyMessage = modelFilter.isEmpty
            ? "No models in the catalog."
            : "No models match \"\(modelFilter)\"."
        return browser
    }

    /// Level 1: the family rows, each tagged with how many of its models are downloaded and what they
    /// occupy, under a heading per group.
    private func localFamilyGroups() -> [ToolsBrowser.Group] {
        var lastGroup: LocalModelGroup?
        return localFamilies.map { provider in
            let downloaded = provider.models.filter { ModelCache.isDownloaded($0.id) }
            let onDisk = downloaded.reduce(0.0) { $0 + $1.approxGB }
            // Fixed-width cells, like the model rows' columns, so the counts line up down the list.
            let marker = downloaded.isEmpty
                ? Paint.fg(Theme.faint.xterm, "○") : Paint.fg(Theme.success.xterm, "✓")
            var trailing = marker + " "
                + Paint.fg(Theme.subtle.xterm, Self.column("\(downloaded.count)", to: 3, alignRight: true))
                + Paint.fg(Theme.faint.xterm, " of "
                    + Self.column("\(provider.models.count)", to: 3, alignRight: true)
                    + (provider.models.count == 1 ? " model " : " models"))
            trailing += Paint.fg(Theme.muted.xterm, Self.column(
                onDisk > 0 ? "~" + Self.diskLabel(onDisk) : "", to: 11, alignRight: true
            ))
            let section = provider.group == lastGroup
                ? nil
                : (title: provider.group.title, tag: provider.group.tag)
            lastGroup = provider.group
            return ToolsBrowser.Group(
                title: provider.name, subtitle: nil, tools: [], trailing: trailing,
                downloaded: !downloaded.isEmpty, section: section
            )
        }
    }

    /// Level 2: the drilled-into provider's model rows, under a heading per role.
    private func localModelGroups() -> [ToolsBrowser.Group] {
        let defaultVariant = DeepAgentVariant.all.first { $0.id == "mispher.deepagent" } ?? DeepAgentVariant.all[0]
        let defaults = Set(defaultVariant.modelIDs)
        return localModelSections.flatMap { section in
            section.models.enumerated().map { index, model -> ToolsBrowser.Group in
                var subtitle = model.capabilityLabel + "  ·  " + model.id
                if defaults.contains(model.id) { subtitle += "  ·  default" }
                return ToolsBrowser.Group(
                    title: model.displayName, subtitle: subtitle, tools: [],
                    trailing: Self.modelColumns(model), downloaded: ModelCache.isDownloaded(model.id),
                    section: index == 0 ? (title: section.role, tag: "\(section.models.count)") : nil,
                    subtitleOnSelection: true
                )
            }
        }
    }

    /// Enter on a level-1 family row: drill into that family's models.
    func openLocalFamily(at index: Int) {
        let families = localFamilies
        guard families.indices.contains(index) else { return }
        localFamily = families[index].key
        toolsBrowser = makeModelsBrowser()
        toolsScrollTop = true
        requestRender()
    }

    /// Esc from a family's model list: back to the grouped family list, that family highlighted.
    func backToLocalFamilies() {
        let key = localFamily
        localFamily = nil
        toolsBrowser = makeModelsBrowser()
        toolsScrollTop = true
        toolsBrowser?.groupIndex = localFamilies.firstIndex { $0.key == key } ?? 0
        requestRender()
    }

    /// An approximate on-disk figure in the same shape the model rows use.
    static func diskLabel(_ gigabytes: Double) -> String {
        gigabytes >= 1 ? String(format: "%.1f GB", gigabytes) : String(format: "%.0f MB", gigabytes * 1024)
    }

    /// A model row's right-hand columns, each cell padded to a fixed width so the rows line up as a
    /// table: the on-disk marker, the weight format, then the download size, context window, and
    /// per-turn output budget. The encoders leave the two token columns blank - they generate nothing.
    static func modelColumns(_ model: MlxModel) -> String {
        let marker = ModelCache.isDownloaded(model.id)
            ? Paint.fg(Theme.success.xterm, "✓")
            : Paint.fg(Theme.faint.xterm, "○")
        let context = model.kind == .retriever ? "" : formatContext(model.contextWindowTokens) + " ctx"
        let output = model.maxOutputTokens.map { formatContext($0) + " out" } ?? ""
        return marker + "   "
            + Paint.fg(Theme.subtle.xterm, column(model.quantizationLabel, to: 12))
            + Paint.fg(Theme.muted.xterm, column(model.sizeLabel, to: 8, alignRight: true))
            + Paint.fg(Theme.faint.xterm, column(context, to: 10, alignRight: true))
            + Paint.fg(Theme.faint.xterm, column(output, to: 9, alignRight: true))
    }

    /// Pad `text` to `width` display columns (left- or right-aligned), truncating if it overruns.
    /// Shared by the Local and Remote model rows, which is what keeps their columns in the same place.
    static func column(_ text: String, to width: Int, alignRight: Bool = false) -> String {
        let shown = TextWidth.truncate(text, to: width)
        let fill = String(repeating: " ", count: max(0, width - TextWidth.of(shown)))
        return alignRight ? fill + shown : shown + fill
    }

    /// Start downloading the model at `index` in the open Local-tab browser (a no-op if it's already
    /// downloaded or another download is in flight). On completion the browser is rebuilt so the row
    /// flips to ✓.
    func startModelDownload(at index: Int) {
        let rows = localModelRows
        guard downloading == nil, rows.indices.contains(index) else { return }
        let model = rows[index]
        guard !ModelCache.isDownloaded(model.id) else { return }
        downloadModels([model.id], label: model.shortName) { [weak self] _ in
            self?.refreshModelsBrowser(keeping: index)
        }
    }

    /// Remove the model at `index` in the open Local-tab browser from the local cache and refresh it.
    func removeModel(at index: Int) {
        let rows = localModelRows
        guard downloading == nil, toolsBrowser?.isModels == true, rows.indices.contains(index) else { return }
        let model = rows[index]
        guard ModelCache.isDownloaded(model.id) else { return }
        ModelCache.remove(model.id)
        refreshModelsBrowser(keeping: index)
        requestRender()
    }

    /// What the Local tab's highlighted row *is* - a model's repo id, or a provider's key - captured
    /// before a filter edit so the rebuilt list can keep the same thing selected rather than a stale
    /// row number.
    var selectedLocalKey: String? {
        guard let browser = toolsBrowser, browser.isModels else { return nil }
        if localFamily == nil {
            let providers = localFamilies
            return providers.indices.contains(browser.groupIndex) ? providers[browser.groupIndex].key : nil
        }
        let rows = localModelRows
        return rows.indices.contains(browser.groupIndex) ? rows[browser.groupIndex].id : nil
    }

    /// The repo id of the highlighted row, or nil on a provider row - what the download / remove keys
    /// act on.
    var selectedLocalModelID: String? {
        guard localFamily != nil, let browser = toolsBrowser, browser.isModels else { return nil }
        let rows = localModelRows
        return rows.indices.contains(browser.groupIndex) ? rows[browser.groupIndex].id : nil
    }

    /// Rebuild the Local tab after a filter edit, keeping `key` highlighted if it survived the filter
    /// (a narrowed list otherwise starts at its top). A search that empties the drilled-into provider
    /// backs out to the provider list rather than showing nothing at all.
    func rebuildModelsBrowser(keeping key: String?) {
        guard toolsBrowser?.isModels == true else { return }
        if localFamily != nil, localModelRows.isEmpty { localFamily = nil }
        toolsBrowser = makeModelsBrowser()
        toolsScrollTop = true
        let rowKeys = localFamily == nil ? localFamilies.map(\.key) : localModelRows.map(\.id)
        toolsBrowser?.groupIndex = key.flatMap(rowKeys.firstIndex(of:)) ?? 0
        requestRender()
    }

    /// Cancel an in-flight download (esc). The partially fetched files stay in the cache and resume
    /// on the next pull; the Local-tab browser, if open, is refreshed.
    func cancelModelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloading = nil
        if toolsBrowser?.isModels == true { refreshModelsBrowser(keeping: toolsBrowser?.groupIndex ?? 0) }
        requestRender()
    }

    /// Rebuild the Local-tab browser (to reflect a new downloaded/removed state) while keeping the
    /// highlighted row.
    private func refreshModelsBrowser(keeping index: Int) {
        guard toolsBrowser?.isModels == true else { return }
        toolsBrowser = makeModelsBrowser()
        if toolsBrowser?.groups.indices.contains(index) == true { toolsBrowser?.groupIndex = index }
    }

    /// Download every not-yet-present id in `ids` behind the in-TUI progress bar (the ``downloading``
    /// state, drawn in the overlay above the input), then run `completion(success)`. Driven by the
    /// `/model` overlay's Local tab. A no-op if a download is already running.
    func downloadModels(_ ids: [String], label: String, completion: @escaping (Bool) -> Void) {
        guard downloading == nil else { return }
        let holder = ProgressHolder()
        downloading = DownloadProgress(label: label, fraction: 0)
        requestRender()
        downloadTask = Task { [weak self] in
            // Animate the bar from the shared fraction while the (off-main-actor) download runs.
            let animation = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, downloading != nil else { break }
                    downloading?.fraction = holder.fraction
                    requestRender()
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            var ok = true
            for id in ids where !ModelCache.isDownloaded(id) {
                if Task.isCancelled { ok = false; break }
                self?.downloading?.modelID = id
                do { try await ModelCache.download(id) { holder.set($0) } } catch { ok = false; break }
            }
            animation.cancel()
            guard let self, !Task.isCancelled else { return }
            downloading = nil
            downloadTask = nil
            completion(ok)
            requestRender()
        }
    }
}

extension MlxModel {
    /// Whether this row survives the Local tab's search box: a case-insensitive substring of anything
    /// the user can see on the row or would think to type - the name, the family, the repo id, what
    /// the model is for, and the weight format ("thinking", "gemma", "4-bit", "vision", "embedding").
    /// An empty query matches everything.
    func matches(query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        let haystack = [displayName, family.title, id, detail, quantizationLabel, roleLabel]
        return haystack.contains { $0.lowercased().contains(query) }
    }
}

/// The live state of an in-TUI model download, drawn as a progress bar above the input box - and,
/// while the `/model` Local tab is open (which hides that overlay), inside the browser panel itself.
struct DownloadProgress {
    let label: String
    var fraction: Double
    /// The catalog id currently being fetched, so the Local tab can mark its row live.
    var modelID: String?
}
