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

    @Test("The Local tab has one row per catalog model, in section order, flagged by downloaded state")
    func modelsBrowserMatchesCatalog() {
        let screen = makeScreen()
        let browser = screen.makeModelsBrowser()
        #expect(browser.isModels)
        #expect(browser.title == "Local models")
        #expect(browser.groups.count == MlxModel.catalog.count)
        // The rows follow `localModelRows` (sectioned), not raw catalog order - the indices the
        // download / remove keys use.
        #expect(Set(screen.localModelRows.map(\.id)) == Set(MlxModel.catalog.map(\.id)))
        for (group, model) in zip(browser.groups, screen.localModelRows) {
            #expect(group.title == model.variantName) // the family lives in the heading, not every row
            #expect(group.downloaded == ModelCache.isDownloaded(model.id)) // reflects the real cache
            #expect(group.trailing != nil) // the ✓/○ + format / size / context / output columns
            #expect(group.subtitle?.contains(model.id) == true) // the id is the highlighted row's subtitle
            #expect(group.subtitleOnSelection) // ...and only that row's
        }
    }

    @Test("Each family opens a section tagged with what it is for, encoders last")
    func modelsBrowserSectionsByFamily() {
        let screen = makeScreen()
        let headings = screen.makeModelsBrowser().groups.compactMap(\.section)
        #expect(headings.map(\.title) == ["LFM2.5", "Ornith", "Qwen3.6", "Gemma 4", "LFM2.5-VL", "LFM2.5-ColBERT"])
        #expect(headings.map(\.tag) == ["Text", "Text + Vision", "Text", "Text", "Vision", "Embedding"])
        // One heading per family, on that family's first row only.
        #expect(screen.makeModelsBrowser().groups.filter { $0.section != nil }.count == headings.count)
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

    @Test("The Local tab's search narrows the rows and keeps the indices aligned")
    func modelsBrowserSearchNarrowsRows() {
        let screen = makeScreen()
        screen.modelFilter = "thinking"
        let rows = screen.localModelRows
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.id.contains("Thinking") })
        #expect(screen.makeModelsBrowser().groups.count == rows.count)

        screen.modelFilter = "embedding" // the role tag is searchable, not just the name
        #expect(screen.localModelRows.allSatisfy { $0.kind == .retriever })

        screen.modelFilter = "vision" // ...and a unified VLM is found by it too, though it is cataloged text
        #expect(screen.localModelRows.contains { $0.id.contains("Ornith") })

        screen.modelFilter = "no-such-model"
        #expect(screen.localModelRows.isEmpty)
        #expect(screen.makeModelsBrowser().emptyMessage.contains("no-such-model"))
    }

    @Test("Typing filters the Local tab and ctrl-x removes, as on the Remote tab")
    func modelsBrowserTypeToFilter() {
        let screen = makeScreen()
        screen.openModelHub(tab: .local)
        #expect(screen.modelFilter.isEmpty)
        for byte in Array("vl".utf8) { #expect(screen.handleModelsBrowserKey(byte)) }
        #expect(screen.modelFilter == "vl")
        #expect(screen.localModelRows.allSatisfy { $0.id.contains("VL") })
        // 'x' is a query character now, not the remove key - ctrl-x is.
        #expect(screen.handleModelsBrowserKey(0x78))
        #expect(screen.modelFilter == "vlx")
        #expect(screen.handleModelsBrowserKey(0x7F)) // backspace
        #expect(screen.modelFilter == "vl")
        // ctrl-x is the remove key: it is consumed rather than typed. Pressed here against a query
        // that matches nothing, so the assertion never deletes a model from the real cache.
        for byte in Array("-no-such-model".utf8) { _ = screen.handleModelsBrowserKey(byte) }
        #expect(screen.localModelRows.isEmpty)
        #expect(screen.handleModelsBrowserKey(0x18))
        #expect(screen.modelFilter == "vl-no-such-model")

        // Esc clears the query first, and only then closes the overlay.
        screen.escapeModelHub()
        #expect(screen.modelFilter.isEmpty)
        #expect(screen.localModelRows.count == MlxModel.catalog.count)
        #expect(screen.modelHub != nil)
        screen.escapeModelHub()
        #expect(screen.modelHub == nil)
    }

    @Test("Refining the query keeps the highlighted model highlighted")
    func modelsBrowserSearchKeepsTheSelection() throws {
        let screen = makeScreen()
        screen.openModelHub(tab: .local)
        for byte in Array("ornith".utf8) { _ = screen.handleModelsBrowserKey(byte) }
        let browser = try #require(screen.toolsBrowser)
        screen.toolsBrowser?.groupIndex = browser.groups.count - 1 // the 8-bit row
        let wanted = screen.selectedLocalModelID
        #expect(wanted?.contains("8bit") == true)
        _ = screen.handleModelsBrowserKey(0x20) // " " - still matches nothing new, list unchanged
        _ = screen.handleModelsBrowserKey(0x7F)
        #expect(screen.selectedLocalModelID == wanted) // not reset to the top
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
            id: "nvidia/nemotron-3-super:free", name: "NVIDIA: Nemotron 3 Super (free)", contextLength: 1_000_000, vision: false
        ),
        OpenRouterModel(
            id: "nvidia/nemotron-3-nano:free", name: "NVIDIA: Nemotron 3 Nano (free)", contextLength: 256_000, vision: true
        ),
        OpenRouterModel(id: "google/gemma-4-31b:free", name: "Google: Gemma 4 31B (free)", contextLength: 262_000, vision: true),
        OpenRouterModel(id: "meta-llama/llama-3.3-70b:free", name: "Meta: Llama 3.3 70B (free)", contextLength: 131_000, vision: false)
    ]

    private func makeScreen() -> ChatScreen {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        return ChatScreen(variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: ApprovalGate())
    }
}
