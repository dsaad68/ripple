import DeepAgents
import DeepAgentsMLX
import Foundation

// The `/model` overlay's Local tab - download / remove the on-device MLX models from inside the REPL -
// and the shared in-TUI download flow it drives. It reuses the ``ToolsBrowser`` overlay (each catalog
// model is a row tagged with its size + downloaded state) and shows a single progress bar above the
// input box while a model downloads. Split out of ChatScreen to keep that file within budget.
extension ChatScreen {
    /// Build the Local-tab browser: one row per ``MlxModel`` in the catalog, tagged with its size and
    /// a ✓/○ downloaded marker, the id as a dimmed subtitle, and a "default" note on the models the
    /// default variant uses.
    func makeModelsBrowser() -> ToolsBrowser {
        let defaultVariant = DeepAgentVariant.all.first { $0.id == "mispher.deepagent" } ?? DeepAgentVariant.all[0]
        let defaults = Set(defaultVariant.modelIDs)
        let groups = MlxModel.catalog.map { model -> ToolsBrowser.Group in
            let downloaded = ModelCache.isDownloaded(model.id)
            let trailing = downloaded
                ? Paint.fg(114, "✓ " + model.sizeLabel)
                : Paint.fg(240, "○ " + model.sizeLabel)
            var subtitle = model.detail + "  ·  " + model.id
            if defaults.contains(model.id) { subtitle += "  ·  default" }
            return ToolsBrowser.Group(
                title: model.displayName, subtitle: subtitle, tools: [],
                trailing: trailing, downloaded: downloaded
            )
        }
        var browser = ToolsBrowser(groups: groups)
        browser.title = "Local models"
        browser.isModels = true
        browser.emptyMessage = "No models in the catalog."
        return browser
    }

    /// Start downloading the catalog model at `index` in the open Local-tab browser (a no-op if it's
    /// already downloaded or another download is in flight). On completion the browser is rebuilt so
    /// the row flips to ✓.
    func startModelDownload(at index: Int) {
        guard downloading == nil, MlxModel.catalog.indices.contains(index) else { return }
        let model = MlxModel.catalog[index]
        guard !ModelCache.isDownloaded(model.id) else { return }
        downloadModels([model.id], label: model.shortName) { [weak self] _ in
            self?.refreshModelsBrowser(keeping: index)
        }
    }

    /// Remove the catalog model at `index` from the local cache and refresh the browser.
    func removeModel(at index: Int) {
        guard downloading == nil, toolsBrowser?.isModels == true,
              MlxModel.catalog.indices.contains(index) else { return }
        let model = MlxModel.catalog[index]
        guard ModelCache.isDownloaded(model.id) else { return }
        ModelCache.remove(model.id)
        refreshModelsBrowser(keeping: index)
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

/// The live state of an in-TUI model download, drawn as a progress bar above the input box - and,
/// while the `/model` Local tab is open (which hides that overlay), inside the browser panel itself.
struct DownloadProgress {
    let label: String
    var fraction: Double
    /// The catalog id currently being fetched, so the Local tab can mark its row live.
    var modelID: String?
}
