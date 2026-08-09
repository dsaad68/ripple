import DeepAgents
import DeepAgentsMLX
import Foundation

// The `/model` overlay's Local tab - download / remove the on-device MLX models from inside the REPL -
// and the shared in-TUI download flow it drives. It reuses the ``ToolsBrowser`` overlay (the catalog
// laid out as a table, sectioned by model family) and shows a single progress bar above the input box
// while a model downloads. Split out of ChatScreen to keep that file within budget.
extension ChatScreen {
    /// The catalog rows the Local tab currently shows: every model, narrowed by ``modelFilter`` and
    /// ordered by ``MlxModel/sections(of:)`` (families in catalog order, chat models first, the
    /// retrieval encoders last). The browser's row indices index *this*, not the raw catalog - a
    /// filtered or regrouped list would otherwise download the wrong model.
    var localModelRows: [MlxModel] {
        MlxModel.sections(of: MlxModel.catalog.filter { $0.matches(query: modelFilter) }).flatMap(\.models)
    }

    /// Build the Local-tab browser: one table row per catalog model - the variant name, a ✓/○ on-disk
    /// marker, the weight format, and the size / context window / output budget in aligned columns -
    /// grouped under a heading per family, with the repo id (plus what it's for, and a "default" note)
    /// as the subtitle of whichever row is highlighted.
    func makeModelsBrowser() -> ToolsBrowser {
        let defaultVariant = DeepAgentVariant.all.first { $0.id == "mispher.deepagent" } ?? DeepAgentVariant.all[0]
        let defaults = Set(defaultVariant.modelIDs)
        let sections = MlxModel.sections(of: MlxModel.catalog.filter { $0.matches(query: modelFilter) })
        let groups = sections.flatMap { section in
            section.models.enumerated().map { index, model -> ToolsBrowser.Group in
                var subtitle = model.capabilityLabel + "  ·  " + model.id
                if defaults.contains(model.id) { subtitle += "  ·  default" }
                return ToolsBrowser.Group(
                    title: model.variantName, subtitle: subtitle, tools: [],
                    trailing: Self.modelColumns(model), downloaded: ModelCache.isDownloaded(model.id),
                    section: index == 0 ? (title: section.family.title, tag: section.roleLabel) : nil,
                    subtitleOnSelection: true
                )
            }
        }
        var browser = ToolsBrowser(groups: groups)
        browser.title = "Local models"
        browser.isModels = true
        browser.emptyMessage = modelFilter.isEmpty
            ? "No models in the catalog."
            : "No models match \"\(modelFilter)\"."
        return browser
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
            + Paint.fg(Theme.subtle.xterm, pad(model.quantizationLabel, to: 12))
            + Paint.fg(Theme.muted.xterm, pad(model.sizeLabel, to: 8, alignRight: true))
            + Paint.fg(Theme.faint.xterm, pad(context, to: 10, alignRight: true))
            + Paint.fg(Theme.faint.xterm, pad(output, to: 9, alignRight: true))
    }

    /// Pad `text` to `width` display columns (left- or right-aligned), truncating if it overruns.
    private static func pad(_ text: String, to width: Int, alignRight: Bool = false) -> String {
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

    /// The repo id of the Local tab's highlighted row - captured *before* a filter edit, so the
    /// rebuilt list can keep the same model selected rather than a stale row number.
    var selectedLocalModelID: String? {
        guard let browser = toolsBrowser, browser.isModels else { return nil }
        let rows = localModelRows
        return rows.indices.contains(browser.groupIndex) ? rows[browser.groupIndex].id : nil
    }

    /// Rebuild the Local tab after a filter edit, keeping `id` highlighted if it survived the filter
    /// (a narrowed list otherwise starts at its top).
    func rebuildModelsBrowser(keeping id: String?) {
        guard toolsBrowser?.isModels == true else { return }
        toolsBrowser = makeModelsBrowser()
        toolsScrollTop = true
        toolsBrowser?.groupIndex = id.flatMap { wanted in localModelRows.firstIndex { $0.id == wanted } } ?? 0
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
