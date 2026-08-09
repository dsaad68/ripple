@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
import MLXLMCommon
@testable import ripple
import Testing

/// The `ripple model` command (download / manage local models) and the in-REPL `/models-config` browser
/// - including its OpenRouter tab's provider grouping and filter. These cover the pure pieces - token
/// resolution, arg parsing, the bar renderer, and the browser view-models - that don't touch the
/// network or the Hugging Face cache (the OpenRouter catalog is injected; live download / remove and
/// the network fetch stay out of unit tests, the same way MCP connect / OAuth do).
@MainActor
struct RippleModelTests {
    private var defaultVariant: DeepAgentVariant {
        DeepAgentVariant.all.first { $0.id == "mispher.deepagent" } ?? DeepAgentVariant.all[0]
    }

    @Test("An exact catalog id resolves to just that id")
    func resolveExactID() {
        let id = "LiquidAI/LFM2.5-350M-MLX-8bit"
        #expect(RippleModelCommand.resolve(id) == [id])
    }

    @Test("A precision-subfolder id resolves, but its bare repo does not")
    func resolveSubfolderID() {
        // The three-component id is the catalog key, so it round-trips through `--model` and
        // `ripple model pull`. The bare repo is not a catalog row and must stay unknown - it names
        // eight precisions, not a model.
        let id = "LiquidAI/LFM2.5-2.6B-MLX/mxfp4"
        #expect(RippleModelCommand.resolve(id) == [id])
        #expect(RippleModelCommand.resolve("LiquidAI/LFM2.5-2.6B-MLX") == nil)
        #expect(RippleModelCommand.resolve("all")?.contains(id) == true)
    }

    @Test("A variant id or label resolves to its planner + vision models")
    func resolveVariant() throws {
        let instruct = try #require(DeepAgentVariant.all.first { $0.id == "mispher.deepagent.instruct" })
        #expect(RippleModelCommand.resolve("mispher.deepagent.instruct") == instruct.modelIDs)
        // The label is matched case-insensitively too.
        #expect(RippleModelCommand.resolve("deepagent") == defaultVariant.modelIDs)
    }

    @Test("`default` and `all` resolve to the default variant and the whole catalog")
    func resolveDefaultAndAll() {
        #expect(RippleModelCommand.resolve("default") == defaultVariant.modelIDs)
        #expect(RippleModelCommand.resolve("all") == MlxModel.catalog.map(\.id))
        #expect(RippleModelCommand.resolve("ALL") == MlxModel.catalog.map(\.id)) // case-insensitive keyword
    }

    @Test("An unknown token resolves to nil")
    func resolveUnknown() {
        #expect(RippleModelCommand.resolve("not-a-real-model") == nil)
    }

    @Test("positionals drops --force / --yes and keeps the model token")
    func positionalsDropFlags() {
        #expect(RippleModelCommand.positionals(["LiquidAI/x", "--force"]) == ["LiquidAI/x"])
        #expect(RippleModelCommand.positionals(["--yes", "all"]) == ["all"])
        #expect(RippleModelCommand.positionals(["--force"]).isEmpty)
    }

    @Test("The progress bar is exactly `width` columns and fills with the fraction")
    func barStringWidthAndFill() {
        #expect(TextWidth.of(CLIProgressBar.barString(fraction: 0.5, width: 22)) == 22)
        #expect(CLIProgressBar.barString(fraction: 1, width: 10).filter { $0 == "█" }.count == 10)
        #expect(CLIProgressBar.barString(fraction: 0, width: 10).filter { $0 == "█" }.count == 0)
    }

    @Test("The Local tab opens on model families, grouped LLM then Embedding")
    func modelsBrowserListsFamilies() {
        let screen = makeScreen()
        let browser = screen.makeModelsBrowser()
        #expect(browser.isModels)
        #expect(browser.title == "Local models")
        #expect(screen.localFamily == nil) // level 1
        #expect(browser.groups.map(\.title) == screen.localFamilies.map(\.name))
        #expect(browser.groups.allSatisfy { $0.trailing != nil }) // downloaded / total / on-disk
        // Two headings, in order, and only on each group's first row.
        let headings = browser.groups.compactMap(\.section)
        #expect(headings.map(\.title) == ["LLM", "Embedding"])
        // One row per model line - LiquidAI's whole LFM2.5 line is one row, vision variants included.
        #expect(browser.groups.map(\.title) == ["LFM2.5", "Ornith", "Qwen3.6", "Gemma 4", "LFM2.5-ColBERT"])
        // Every model is reachable through exactly one family row, and the encoders sit apart from
        // the models you can actually chat to.
        #expect(screen.localFamilies.flatMap(\.models).count == MlxModel.catalog.count)
        let llm = screen.localFamilies.filter { $0.group == .llm }.flatMap(\.models)
        let embedding = screen.localFamilies.filter { $0.group == .embedding }.flatMap(\.models)
        #expect(llm.allSatisfy { $0.kind != .retriever })
        #expect(embedding.allSatisfy { $0.kind == .retriever })
        #expect(Set(embedding.map(\.id)) == Set(MlxModel.retrieverCatalog.map(\.id)))
        // No model rows at level 1, so the download / remove keys, which index them, are inert.
        #expect(screen.localModelRows.isEmpty)
        #expect(screen.selectedLocalModelID == nil)
    }

    @Test("Opening a family lists just its models, under a heading per role")
    func modelsBrowserDrillsIntoAFamily() throws {
        let screen = makeScreen()
        screen.openModelHub(tab: .local)
        let index = try #require(screen.localFamilies.firstIndex { $0.family == .lfm2 })
        screen.openLocalFamily(at: index)
        #expect(screen.localFamily == "LLM/LFM2.5")

        let browser = try #require(screen.toolsBrowser)
        #expect(browser.groups.map(\.title) == screen.localModelRows.map(\.displayName))
        #expect(screen.localModelRows.allSatisfy { $0.family == .lfm2 })
        // The vision conversions are the same line, so they come along - separated by role, not by a
        // second family row.
        #expect(browser.groups.compactMap(\.section).map(\.title) == ["Text", "Vision"])
        #expect(screen.localModelRows.contains { $0.id.contains("LFM2.5-VL") })
        for (group, model) in zip(browser.groups, screen.localModelRows) {
            #expect(group.downloaded == ModelCache.isDownloaded(model.id)) // reflects the real cache
            #expect(group.subtitle?.contains(model.id) == true) // the id is the highlighted row's subtitle
            #expect(group.subtitleOnSelection) // ...and only that row's
        }

        // Esc backs out to the family list with that family still highlighted, then closes.
        screen.escapeModelHub()
        #expect(screen.localFamily == nil)
        #expect(screen.toolsBrowser?.groupIndex == index)
        screen.escapeModelHub()
        #expect(screen.modelHub == nil)
    }

    @Test("A family that takes images splits into Text + Vision and Text")
    func unifiedVLMSplitsByRole() throws {
        let screen = makeScreen()
        screen.openModelHub(tab: .local)
        let index = try #require(screen.localFamilies.firstIndex { $0.family == .ornith })
        screen.openLocalFamily(at: index)
        #expect(screen.toolsBrowser?.groups.compactMap(\.section).map(\.title) == ["Text + Vision"])
    }

    @Test("The Embedding group drills into the encoders alone")
    func embeddingGroupIsItsOwnDrill() throws {
        let screen = makeScreen()
        screen.openModelHub(tab: .local)
        let index = try #require(screen.localFamilies.firstIndex { $0.group == .embedding })
        screen.openLocalFamily(at: index)
        #expect(screen.localModelRows.allSatisfy { $0.kind == .retriever })
        #expect(screen.toolsBrowser?.groups.compactMap(\.section).map(\.title) == ["Embedding"])
    }

    @Test("A row's columns carry the size, context window and output budget")
    func modelRowColumnsCarryTheNumbers() {
        guard let model = MlxModel.catalog.first(where: { $0.id.contains("Qwen3.6-27B") }) else {
            Issue.record("the Qwen3.6 27B row is expected in the catalog")
            return
        }
        let columns = ChatScreen.modelColumns(model)
        #expect(columns.contains("20.0 GB"))
        #expect(columns.contains("262k ctx")) // the card's native window
        #expect(columns.contains("32k out")) // what `agentParameters` will generate
        #expect(columns.contains("OptiQ 4-bit"))
    }

    @Test("An encoder row shows its size but no token columns - it generates nothing")
    func retrieverRowHasNoTokenColumns() {
        guard let model = MlxModel.retrieverCatalog.first else {
            Issue.record("a retrieval encoder is expected in the catalog")
            return
        }
        let columns = ChatScreen.modelColumns(model)
        #expect(columns.contains(model.sizeLabel))
        #expect(!columns.contains("ctx"))
        #expect(!columns.contains("out"))
    }

    @Test("A search narrows both levels - the family list and the models inside one")
    func modelsBrowserSearchNarrowsBothLevels() {
        let screen = makeScreen()
        screen.modelFilter = "thinking"
        // Only LFM2.5 has a Thinking row, so the family list collapses to it.
        #expect(screen.localFamilies.map(\.name) == ["LFM2.5"])
        #expect(screen.localFamilies.flatMap(\.models).allSatisfy { $0.id.contains("Thinking") })

        screen.modelFilter = "embedding" // the role tag is searchable, not just the name
        #expect(screen.localFamilies.allSatisfy { $0.group == .embedding })

        screen.modelFilter = "vision" // ...and a unified VLM is found by it too, though it is cataloged text
        #expect(screen.localFamilies.flatMap(\.models).contains { $0.id.contains("Ornith") })

        screen.modelFilter = "no-such-model"
        #expect(screen.localFamilies.isEmpty)
        #expect(screen.makeModelsBrowser().emptyMessage.contains("no-such-model"))
    }

    @Test("Typing filters the Local tab and ctrl-x removes, as on the Remote tab")
    func modelsBrowserTypeToFilter() {
        let screen = makeScreen()
        screen.openModelHub(tab: .local)
        #expect(screen.modelFilter.isEmpty)
        for byte in Array("vl".utf8) { #expect(screen.handleModelsBrowserKey(byte)) }
        #expect(screen.modelFilter == "vl")
        #expect(screen.localFamilies.flatMap(\.models).allSatisfy { $0.id.contains("VL") })
        // 'x' is a query character now, not the remove key - ctrl-x is.
        #expect(screen.handleModelsBrowserKey(0x78))
        #expect(screen.modelFilter == "vlx")
        #expect(screen.handleModelsBrowserKey(0x7F)) // backspace
        #expect(screen.modelFilter == "vl")
        // ctrl-x is the remove key: it is consumed rather than typed. Pressed here against a query
        // that matches nothing, so the assertion never deletes a model from the real cache.
        for byte in Array("-no-such-model".utf8) { _ = screen.handleModelsBrowserKey(byte) }
        #expect(screen.localFamilies.isEmpty)
        #expect(screen.handleModelsBrowserKey(0x18))
        #expect(screen.modelFilter == "vl-no-such-model")

        // Esc clears the query first, and only then closes the overlay.
        screen.escapeModelHub()
        #expect(screen.modelFilter.isEmpty)
        #expect(screen.localFamilies.flatMap(\.models).count == MlxModel.catalog.count)
        #expect(screen.modelHub != nil)
        screen.escapeModelHub()
        #expect(screen.modelHub == nil)
    }

    @Test("Refining the query keeps the highlighted model highlighted")
    func modelsBrowserSearchKeepsTheSelection() throws {
        let screen = makeScreen()
        screen.openModelHub(tab: .local)
        for byte in Array("ornith".utf8) { _ = screen.handleModelsBrowserKey(byte) }
        screen.openLocalFamily(at: 0)
        let browser = try #require(screen.toolsBrowser)
        screen.toolsBrowser?.groupIndex = browser.groups.count - 1 // the 8-bit row
        let wanted = screen.selectedLocalModelID
        #expect(wanted?.contains("8bit") == true)
        _ = screen.handleModelsBrowserKey(0x20) // " " - still matches nothing new, list unchanged
        _ = screen.handleModelsBrowserKey(0x7F)
        #expect(screen.selectedLocalModelID == wanted) // not reset to the top
    }

    @Test("A search that empties the open provider backs out rather than showing nothing")
    func searchEmptyingAProviderBacksOut() {
        let screen = makeScreen()
        screen.openModelHub(tab: .local)
        screen.openLocalFamily(at: 0)
        #expect(screen.localFamily != nil)
        for byte in Array("zzz".utf8) { _ = screen.handleModelsBrowserKey(byte) }
        #expect(screen.localFamily == nil)
    }

    @Test("Local and Remote are the same view: providers, then models under a role heading")
    func localAndRemoteMirrorEachOther() throws {
        let screen = makeScreen()
        screen.openRouterCatalog = Self.sampleOpenRouterCatalog

        // Level 1 on both: provider rows, no drill-in set, with a right-hand summary.
        screen.openModelHub(tab: .local)
        let localLevel1 = try #require(screen.toolsBrowser)
        screen.openRouterProvider = nil
        let remoteLevel1 = screen.makeOpenRouterBrowser()
        #expect(localLevel1.groups.allSatisfy { $0.trailing != nil })
        #expect(remoteLevel1.groups.allSatisfy { $0.trailing != nil })

        // Level 2 on both: model rows sectioned by role, the id as a selection-only subtitle, and the
        // same columns in the same places.
        screen.openLocalFamily(at: 0)
        let localRows = try #require(screen.toolsBrowser).groups
        screen.openRouterProvider = "NVIDIA"
        let remoteRows = screen.makeOpenRouterBrowser().groups
        #expect(localRows.compactMap(\.section).allSatisfy { ["Text", "Text + Vision", "Vision"].contains($0.title) })
        #expect(remoteRows.compactMap(\.section).allSatisfy { ["Text", "Text + Vision"].contains($0.title) })
        #expect(remoteRows.allSatisfy { $0.subtitleOnSelection })
        // A remote row carries the same context / output facts a local one does.
        let nano = try #require(Self.sampleOpenRouterCatalog.first { $0.id.contains("nano") })
        let columns = ChatScreen.remoteModelColumns(nano, isAdded: false)
        #expect(columns.contains("256k ctx"))
        #expect(nano.roleLabel == "Text + Vision") // it takes images
        let super3 = try #require(Self.sampleOpenRouterCatalog.first { $0.id.contains("super") })
        #expect(ChatScreen.remoteModelColumns(super3, isAdded: true).contains("16k out"))
        #expect(super3.roleLabel == "Text")
    }

    @Test("Model management is unified under /model (the standalone /models-config is retired)")
    func modelCommandName() {
        let names = ChatScreen.commands.map(\.name)
        #expect(names.contains("/model")) // the one model command (Select / Local / Remote tabs)
        #expect(!names.contains("/models-config")) // folded into /model (kept only as a hidden alias)
        #expect(!names.contains("/models"))
    }

    @Test("The OpenRouter tab's level 1 lists providers, sorted by label, with each provider's models")
    func openRouterProviderList() {
        let screen = makeScreen()
        screen.openRouterCatalog = Self.sampleOpenRouterCatalog
        #expect(screen.orderedOpenRouterProviders.map(\.label) == ["Google", "Meta", "NVIDIA"]) // sorted
        #expect(screen.orderedOpenRouterProviders.first { $0.label == "NVIDIA" }?.models.count == 2)

        let browser = screen.makeOpenRouterBrowser()
        #expect(browser.isOpenRouter)
        #expect(browser.groups.map(\.title) == ["Google", "Meta", "NVIDIA"]) // one row per provider
    }

    @Test("Drilling into a provider lists just its models, sorted by short name")
    func openRouterProviderModels() {
        let screen = makeScreen()
        screen.openRouterCatalog = Self.sampleOpenRouterCatalog
        screen.openRouterProvider = "NVIDIA"
        #expect(screen.currentProviderModels.map(\.shortName) == ["Nemotron 3 Nano", "Nemotron 3 Super"])
        #expect(screen.makeOpenRouterBrowser().groups.map(\.title) == ["Nemotron 3 Nano", "Nemotron 3 Super"])
    }

    @Test("The OpenRouter filter narrows by provider label or model name")
    func openRouterFilter() {
        let screen = makeScreen()
        screen.openRouterCatalog = Self.sampleOpenRouterCatalog
        screen.openRouterFilter = "nvidia" // matches the provider label
        #expect(screen.orderedOpenRouterProviders.map(\.label) == ["NVIDIA"])
        screen.openRouterFilter = "gemma" // matches a model name
        #expect(screen.orderedOpenRouterProviders.map(\.label) == ["Google"])
    }

    /// A small injected OpenRouter catalog (two NVIDIA models, one Google, one Meta) so the grouping /
    /// filter tests run offline.
    private static let sampleOpenRouterCatalog: [OpenRouterModel] = [
        OpenRouterModel(
            id: "nvidia/nemotron-3-super:free", name: "NVIDIA: Nemotron 3 Super (free)",
            contextLength: 1_000_000, maxCompletionTokens: 16384, vision: false
        ),
        OpenRouterModel(
            id: "nvidia/nemotron-3-nano:free", name: "NVIDIA: Nemotron 3 Nano (free)",
            contextLength: 256_000, maxCompletionTokens: nil, vision: true
        ),
        OpenRouterModel(
            id: "google/gemma-4-31b:free", name: "Google: Gemma 4 31B (free)",
            contextLength: 262_000, maxCompletionTokens: 8192, vision: true
        ),
        OpenRouterModel(
            id: "meta-llama/llama-3.3-70b:free", name: "Meta: Llama 3.3 70B (free)",
            contextLength: 131_000, maxCompletionTokens: nil, vision: false
        )
    ]

    private func makeScreen() -> ChatScreen {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        return ChatScreen(variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: ApprovalGate())
    }
}
