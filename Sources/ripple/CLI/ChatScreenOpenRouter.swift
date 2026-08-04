import Foundation

// The `/model` overlay's Remote tab - browse the free models from OpenRouter's public catalog and
// toggle them into `~/.ripple/settings.json` so they join the model lists. ←/→ (or Tab) switches
// between the overlay's tabs (see ChatScreenModelHub / ChatScreenInput). Two levels, both reusing the
// ``ToolsBrowser`` overlay: a provider list (enter drills in), then that provider's models (enter
// toggles add/remove; esc goes back). The catalog is fetched once per session.
extension ChatScreen {
    /// The working directory used to load/merge `settings.json` (the cwd, or the home dir as the
    /// global-only fallback) - matches what ``DeepAgentREPL`` loaded the variants from.
    var modelsWorkingDirectory: URL {
        workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// The free models matching ``openRouterFilter`` (a case-insensitive substring of the provider
    /// label, id, or name - so typing "nvidia" / "google" filters by provider). The source the
    /// provider list and a provider's model list are both derived from.
    var filteredOpenRouterModels: [OpenRouterModel] {
        let all = openRouterCatalog ?? []
        let query = openRouterFilter.lowercased()
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.providerLabel.lowercased().contains(query)
                || $0.id.lowercased().contains(query)
                || $0.name.lowercased().contains(query)
        }
    }

    /// The providers (matching the filter), each with its models, sorted by provider label - the
    /// top-level rows of the OpenRouter tab.
    var orderedOpenRouterProviders: [(label: String, models: [OpenRouterModel])] {
        Dictionary(grouping: filteredOpenRouterModels, by: \.providerLabel)
            .map { (label: $0.key, models: $0.value.sorted(by: Self.byShortName)) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// The drilled-into provider's models (matching the filter), sorted - the level-2 rows.
    var currentProviderModels: [OpenRouterModel] {
        guard let provider = openRouterProvider else { return [] }
        return filteredOpenRouterModels.filter { $0.providerLabel == provider }.sorted(by: Self.byShortName)
    }

    private static func byShortName(_ lhs: OpenRouterModel, _ rhs: OpenRouterModel) -> Bool {
        lhs.shortName.localizedCaseInsensitiveCompare(rhs.shortName) == .orderedAscending
    }

    /// Open the `/model` overlay's Remote (OpenRouter) tab. Resets to the top-level provider list with
    /// no filter, shows the (possibly empty) pane at once, and kicks off the catalog fetch the first
    /// time; later toggles reuse the cached catalog.
    func showOpenRouterTab() {
        openRouterFilter = ""
        openRouterProvider = nil
        toolsBrowser = makeOpenRouterBrowser()
        toolsScrollTop = true
        if openRouterCatalog == nil { startOpenRouterFetch() }
    }

    /// While the OpenRouter tab is open, printable keys build the filter query and backspace edits it
    /// (Ctrl-U clears it) - so a long free list can be narrowed, e.g. by provider. Enter/arrows/Tab
    /// are left for navigation. Returns true when the key was a filter edit (so it isn't handled
    /// elsewhere).
    func handleOpenRouterFilterKey(_ byte: UInt8) -> Bool {
        guard toolsBrowser?.isOpenRouter == true else { return false }
        switch byte {
        case 0x15: // Ctrl-U clears the filter
            guard !openRouterFilter.isEmpty else { return false }
            openRouterFilter = ""
        case 0x7F, 0x08: // backspace
            guard !openRouterFilter.isEmpty else { return false }
            openRouterFilter.removeLast()
        case 0x20 ... 0x7E: // printable ASCII narrows the list
            openRouterFilter.append(Character(UnicodeScalar(byte)))
        default:
            return false
        }
        refreshOpenRouterBrowser(keeping: 0) // the narrowed list is shorter; start at its top
        requestRender()
        return true
    }

    /// Fetch OpenRouter's free-model catalog off the main loop, rebuilding the open pane when it lands
    /// (success caches the catalog; failure shows the reason). A no-op if a fetch is already running.
    func startOpenRouterFetch() {
        guard openRouterFetch == nil else { return }
        openRouterError = nil
        if toolsBrowser?.isOpenRouter == true { toolsBrowser = makeOpenRouterBrowser() } // reflect "Fetching…"
        requestRender()
        openRouterFetch = Task {
            let result: Result<[OpenRouterModel], Error>
            do { result = try await .success(OpenRouterCatalog.fetch()) } catch { result = .failure(error) }
            if Task.isCancelled { return } // esc cancelled it; onEscape already cleared the state
            switch result {
            case .success(let models): openRouterCatalog = models; openRouterError = nil
            case .failure(let error):
                let reason = (error as? OpenRouterCatalogError)?.description ?? error.localizedDescription
                openRouterError = "OpenRouter: \(reason) - press tab to retry."
            }
            openRouterFetch = nil
            if toolsBrowser?.isOpenRouter == true { toolsBrowser = makeOpenRouterBrowser() }
            requestRender()
        }
    }

    /// Build the OpenRouter tab. Level 1 (no provider drilled into) is one row per provider with its
    /// free-model count (and how many are already added); level 2 is the chosen provider's models, one
    /// readable line each, tagged ✓ added / ○ with the context window and a vision marker. The empty
    /// message reflects the fetch state, and a banner warns when `OPENROUTER_API_KEY` is unset.
    func makeOpenRouterBrowser() -> ToolsBrowser {
        let added = Set(RippleModelConfig.loadModels(workingDirectory: modelsWorkingDirectory).map(\.name))
        let groups: [ToolsBrowser.Group] = openRouterProvider == nil
            ? orderedOpenRouterProviders.map { provider in providerRow(provider, added: added) }
            : currentProviderModels.map { model in modelRow(model, isAdded: added.contains(model.id)) }
        var browser = ToolsBrowser(groups: groups)
        browser.title = "OpenRouter (free)"
        browser.isOpenRouter = true
        if let openRouterError {
            browser.emptyMessage = openRouterError
        } else if openRouterFetch != nil {
            browser.emptyMessage = "Fetching free models from OpenRouter…"
        } else if !openRouterFilter.isEmpty {
            browser.emptyMessage = "No free models match \"\(openRouterFilter)\"."
        } else {
            browser.emptyMessage = "No free models found."
        }
        if (ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? "").isEmpty {
            browser.banner = "⚠ OPENROUTER_API_KEY not set - export it to use these models"
        }
        return browser
    }

    /// A level-1 provider row: the provider name with its free-model count and, in green, how many of
    /// them are already in `settings.json`.
    private func providerRow(_ provider: (label: String, models: [OpenRouterModel]), added: Set<String>) -> ToolsBrowser.Group {
        let addedCount = provider.models.filter { added.contains($0.id) }.count
        let countLabel = provider.models.count == 1 ? "1 free" : "\(provider.models.count) free"
        let trailing = addedCount > 0
            ? Paint.fg(114, "✓ \(addedCount)") + Paint.fg(240, " · " + countLabel)
            : Paint.fg(240, countLabel)
        return ToolsBrowser.Group(title: provider.label, tools: [], trailing: trailing)
    }

    /// A level-2 model row: the readable short name on the left; ✓ added / ○, the context window, and
    /// a vision marker on the right - one line, no second subtitle line.
    private func modelRow(_ model: OpenRouterModel, isAdded: Bool) -> ToolsBrowser.Group {
        var trailing = isAdded ? Paint.fg(114, "✓ added") : Paint.fg(240, "○")
        if let context = model.contextLength { trailing += Paint.fg(240, "   " + Self.formatContext(context)) }
        if model.vision { trailing += Paint.fg(244, "   vision") }
        return ToolsBrowser.Group(title: model.shortName, tools: [], trailing: trailing, downloaded: isAdded)
    }

    /// Enter on a level-1 provider row: drill into that provider's model list.
    func openOpenRouterProvider(at index: Int) {
        let providers = orderedOpenRouterProviders
        guard providers.indices.contains(index) else { return }
        openRouterProvider = providers[index].label
        toolsBrowser = makeOpenRouterBrowser()
        toolsScrollTop = true
        requestRender()
    }

    /// Esc from a provider's model list: back to the top-level provider list.
    func backToOpenRouterProviders() {
        openRouterProvider = nil
        toolsBrowser = makeOpenRouterBrowser()
        toolsScrollTop = true
        requestRender()
    }

    /// Enter on a level-2 model row: add the model to `~/.ripple/settings.json` (an ``OpenAIModelConfig``
    /// entry pointed at OpenRouter, with `apiKey` referencing `$OPENROUTER_API_KEY`) if it isn't there,
    /// else remove it. Rebuilds the `/model` variants so the change shows without a restart.
    func toggleOpenRouterModel(at index: Int) {
        let models = currentProviderModels
        guard models.indices.contains(index) else { return }
        let model = models[index]
        let alreadyAdded = RippleModelConfig.loadModels(workingDirectory: modelsWorkingDirectory)
            .contains { $0.name == model.id }
        do {
            if alreadyAdded {
                try RippleModelConfig.removeModelEntry(name: model.id, from: RippleModelConfig.userFileURL)
            } else {
                var entry: [String: Any] = [
                    "baseURL": "${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}",
                    "model": model.id,
                    "apiKey": "$OPENROUTER_API_KEY"
                ]
                if model.vision { entry["vision"] = true }
                // Carry the catalog's advertised context window so summarization's 85% trigger and
                // the context meter size against the real window rather than the default.
                if let contextLength = model.contextLength { entry["contextWindow"] = contextLength }
                try RippleModelConfig.saveModelEntry(name: model.id, entry, to: RippleModelConfig.userFileURL)
            }
            reloadRemoteModels()
            openRouterError = nil
        } catch {
            openRouterError = "Couldn't write settings.json - \(error.localizedDescription)"
        }
        refreshOpenRouterBrowser(keeping: index)
        requestRender()
    }

    /// Rebuild the OpenRouter tab (to reflect a new added/removed state) while keeping the highlighted
    /// row.
    func refreshOpenRouterBrowser(keeping index: Int) {
        guard toolsBrowser?.isOpenRouter == true else { return }
        toolsBrowser = makeOpenRouterBrowser()
        if toolsBrowser?.groups.indices.contains(index) == true { toolsBrowser?.groupIndex = index }
    }

    /// Reload the user's remote (OpenAI-compatible) models from `settings.json` and rebuild the
    /// selectable `variants`, so a just-added/removed OpenRouter model appears (or disappears) without
    /// restarting. Mirrors how ``DeepAgentREPL`` builds the initial variant list.
    func reloadRemoteModels() {
        let remote = RippleModelConfig.loadModels(workingDirectory: modelsWorkingDirectory)
        variants = DeepAgentVariant.all + remote.map(DeepAgentVariant.remote)
    }

    /// A compact context-window label: `131072` -> "131k", `1048576` -> "1M".
    static func formatContext(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return "\(tokens / 1_000_000)M" }
        if tokens >= 1000 { return "\(tokens / 1000)k" }
        return "\(tokens)"
    }
}
