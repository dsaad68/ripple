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

    @Test("The /models-config browser has one row per catalog model, flagged by downloaded state")
    func modelsBrowserMatchesCatalog() {
        let browser = makeScreen().makeModelsBrowser()
        #expect(browser.isModels)
        #expect(browser.title == "Local models")
        #expect(browser.groups.count == MlxModel.catalog.count)
        for (group, model) in zip(browser.groups, MlxModel.catalog) {
            #expect(group.title == model.displayName)
            #expect(group.downloaded == ModelCache.isDownloaded(model.id)) // reflects the real cache
            #expect(group.trailing != nil) // size + ✓/○, replacing the tool count
            #expect(group.subtitle?.contains(model.id) == true) // the id is the dimmed subtitle
        }
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
