@testable import DeepAgents
@testable import DeepAgentsMLX
import Foundation
@testable import ripple
import Testing

/// The `/config` "Lazy Tools" tab and the wiring that turns its policy into agent inputs.
///
/// The subtle one is the MCP row. Tiers for built-in toolsets are stored as the *demotions*
/// (`auxiliaryMiddleware`), but MCP servers default to auxiliary, so theirs are stored as the
/// *promotions* (`coreMCPServers`) - an inversion that reads correctly in the data and would be very
/// easy to get backwards in the toggle.
@MainActor
struct LazyToolsConfigTests {
    private func editorOnLazyTab(_ policy: AgentToolPolicy, servers: [MCPServerConfig] = []) -> ConfigEditor {
        var editor = ConfigEditor(policy: policy)
        editor.tab = .lazyTools
        editor.mcpServers = servers
        return editor
    }

    private func select(_ editor: inout ConfigEditor, rowID: String) {
        editor.index = editor.rows.firstIndex { $0.id == rowID } ?? 0
    }

    @Test("The tab explains itself, because the trade-off is not visible in the row names")
    func tabCarriesAnExplanation() {
        #expect(ConfigEditor.Tab.lazyTools.explanation.contains("search_tools"))
        // Every tab says what it governs, not just the one whose trade-off is hardest to see.
        for tab in ConfigEditor.Tab.allCases {
            #expect(tab.explanation.count > 80, "\(tab.title) needs a real explanation")
        }
    }

    @Test("Lazy tools is the one experimental tab, and its box warns rather than informs")
    func experimentalTabWarns() {
        #expect(ConfigEditor.Tab.lazyTools.isExperimental)
        #expect(ConfigEditor.Tab.allCases.filter(\.isExperimental) == [.lazyTools])
        #expect(ConfigEditor.Tab.lazyTools.explanation.lowercased().hasPrefix("experimental"))

        let screen = makeScreen()
        let warning = screen.tabExplanationLines(.lazyTools, width: 100)
        let plain = screen.tabExplanationLines(.capabilities, width: 100)
        #expect(warning[0].text.contains("lazy tools - EXPERIMENTAL!"))
        #expect(warning[0].text.contains("⚠")) // the warning glyph, not the ⓘ
        #expect(!warning[0].text.contains("ⓘ"))
        #expect(plain[0].text.contains("ⓘ")) // ...and only that tab's
        #expect(!plain[0].text.contains("EXPERIMENTAL"))
        // The box still lines up: an experimental tab is a colour and a title, not a different shape.
        let box = warning.dropLast()
        #expect(box.allSatisfy { TextWidth.of($0.text) == TextWidth.of(box[0].text) })
    }

    @Test("The Sandbox tab warns that its one switch needs a tool macOS does not ship")
    func sandboxTabStatesItsRequirement() throws {
        #expect(ConfigEditor.Tab.allCases.filter { $0.requirement != nil } == [.sandbox])
        let requirement = try #require(ConfigEditor.Tab.sandbox.requirement)
        #expect(requirement.title == "needs apple containers")
        #expect(requirement.text.contains("github.com/apple/container")) // where to get it
        #expect(requirement.text.contains("container system start")) // ...and what to run after

        // Two boxes on that tab - the blue explanation, then the amber requirement - and the rows
        // still follow. A tab with no requirement gets one box.
        let screen = makeScreen()
        let sandbox = screen.tabExplanationLines(.sandbox, width: 100)
        let borders = sandbox.filter { $0.text.contains("╭─") }
        #expect(borders.count == 2)
        #expect(borders[0].text.contains("ⓘ"))
        #expect(borders[1].text.contains("⚠"))
        #expect(borders[1].text.contains("needs apple containers"))
        #expect(screen.tabExplanationLines(.context, width: 100).filter { $0.text.contains("╭─") }.count == 1)
        // Both boxes keep the panel aligned.
        let boxed = sandbox.filter { !$0.text.isEmpty }
        #expect(boxed.allSatisfy { TextWidth.of($0.text) == TextWidth.of(boxed[0].text) })
    }

    private func makeScreen() -> ChatScreen {
        let agent = RippleDeepAgent.make(textModel: FakeChatModel(answer: "x"))
        return ChatScreen(variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: ApprovalGate())
    }

    @Test("Lazy tools is off by default and toggles with space")
    func featureSwitch() throws {
        var editor = editorOnLazyTab(.init())
        select(&editor, rowID: ConfigEditor.toolSearchRowID)
        #expect(try !editor.isOn(#require(editor.current)))
        editor.toggle()
        #expect(editor.policy.toolSearch)
    }

    @Test("Everything below the switch is locked until the feature is on")
    func rowsLockedWhileOff() throws {
        var editor = editorOnLazyTab(.init(), servers: [MCPServerConfig(name: "deepwiki", kind: .http)])
        for rowID in [ConfigEditor.retrieverRowID, ConfigEditor.searchLimitRowID,
                      ConfigEditor.tierRowPrefix + "git", ConfigEditor.mcpTierRowPrefix + "deepwiki"] {
            select(&editor, rowID: rowID)
            let row = try #require(editor.current)
            #expect(editor.isLocked(row), "\(rowID) should be locked while lazy tools are off")
            editor.toggle()
        }
        // A locked row must not have quietly changed anything.
        #expect(editor.policy.auxiliaryMiddleware.isEmpty)
        #expect(editor.policy.coreMCPServers.isEmpty)
        #expect(editor.policy.toolSearchModel == nil)
    }

    @Test("A toolset row moves between core and auxiliary")
    func toolsetTierToggles() throws {
        var editor = editorOnLazyTab(.init(toolSearch: true))
        select(&editor, rowID: ConfigEditor.tierRowPrefix + "git")
        #expect(try editor.stateLabel(#require(editor.current)) == "core")
        editor.toggle()
        #expect(editor.policy.auxiliaryMiddleware.contains("git"))
        #expect(try editor.stateLabel(#require(editor.current)) == "auxiliary")
        editor.toggle()
        #expect(!editor.policy.auxiliaryMiddleware.contains("git"))
    }

    @Test("An MCP row defaults to auxiliary and stores its promotion to core")
    func mcpTierToggles() throws {
        let servers = [MCPServerConfig(name: "deepwiki", kind: .http)]
        var editor = editorOnLazyTab(.init(toolSearch: true), servers: servers)
        select(&editor, rowID: ConfigEditor.mcpTierRowPrefix + "deepwiki")
        // Auxiliary with nothing stored - the inversion, visible.
        #expect(try editor.stateLabel(#require(editor.current)) == "auxiliary")
        #expect(editor.policy.coreMCPServers.isEmpty)
        editor.toggle()
        #expect(editor.policy.coreMCPServers == ["deepwiki"])
        #expect(try editor.stateLabel(#require(editor.current)) == "core")
        editor.toggle()
        #expect(editor.policy.coreMCPServers.isEmpty) // back to the default, not to "explicitly aux"
    }

    @Test("The retriever cycles lexical → 8-bit → bf16 → lexical")
    func retrieverCycles() throws {
        var editor = editorOnLazyTab(.init(toolSearch: true))
        select(&editor, rowID: ConfigEditor.retrieverRowID)
        #expect(try editor.stateLabel(#require(editor.current)).contains("lexical"))
        editor.toggle()
        #expect(editor.policy.toolSearchModel == ToolSearchModel.colbert350m8bit.repoID)
        editor.toggle()
        #expect(editor.policy.toolSearchModel == ToolSearchModel.colbert350mBF16.repoID)
        editor.toggle()
        #expect(editor.policy.toolSearchModel == nil) // wraps
    }

    @Test("The retriever row says whether the weights are on disk")
    func retrieverShowsDownloadState() throws {
        // Without this the choice looks free and the cost lands as the first search silently blocking
        // on a few hundred MB.
        var editor = editorOnLazyTab(
            .init(toolSearch: true, toolSearchModel: ToolSearchModel.colbert350m8bit.repoID)
        )
        select(&editor, rowID: ConfigEditor.retrieverRowID)
        let label = try editor.stateLabel(#require(editor.current))
        #expect(label.contains("ready") || label.contains("not downloaded"))
    }

    @Test("Top matches cycles through the offered counts")
    func limitCycles() throws {
        var editor = editorOnLazyTab(.init(toolSearch: true))
        select(&editor, rowID: ConfigEditor.searchLimitRowID)
        #expect(try editor.stateLabel(#require(editor.current)) == "5")
        editor.toggle()
        #expect(ConfigEditor.searchLimitChoices.contains(editor.policy.toolSearchLimit))
        #expect(editor.policy.toolSearchLimit != 5)
    }
}

/// `RippleDeepAgent.toolSearchInputs` is the one place both entry points (`ripple chat` and the
/// headless run) derive their lazy-tool wiring, so the interactive and non-interactive agents cannot
/// disagree about tiers or retriever.
@MainActor
struct ToolSearchInputsTests {
    private let servers = [
        MCPServerConfig(name: "deepwiki", kind: .http),
        MCPServerConfig(name: "notes", kind: .stdio)
    ]

    /// A stand-in for a loaded MCP tool. `toolsFromServer` attributes purely through
    /// ``ServerScopedTool``, so this exercises the real attribution path without needing a live server
    /// session to build an `MCPTool`.
    private struct StubServerTool: ServerScopedTool {
        let serverName: String
        let toolName: String
        var name: String { "\(serverName)__\(toolName)" }
        var description: String { "Ask \(serverName) a question." }
        func execute(
            _ arguments: [String: AgentJSON], _ context: ToolContext
        ) async throws -> ToolOutput {
            ToolOutput("ok")
        }
    }

    private var tools: [any AgentTool] {
        [StubServerTool(serverName: "deepwiki", toolName: "ask_question")]
    }

    @Test("With the feature off nothing is auxiliary and no retriever is built")
    func offMeansInert() {
        let inputs = RippleDeepAgent.toolSearchInputs(
            policy: .init(), servers: servers, mcpTools: tools
        )
        #expect(inputs.auxiliary.isEmpty)
        #expect(inputs.retriever == nil)
    }

    @Test("An MCP server left at its default is auxiliary; a promoted one is not")
    func mcpTiersFlowThrough() {
        let auxiliary = RippleDeepAgent.toolSearchInputs(
            policy: .init(toolSearch: true), servers: servers, mcpTools: tools
        ).auxiliary
        #expect(auxiliary.contains { $0.contains("ask_question") })

        let promoted = RippleDeepAgent.toolSearchInputs(
            policy: .init(toolSearch: true, coreMCPServers: ["deepwiki"]),
            servers: servers, mcpTools: tools
        ).auxiliary
        #expect(promoted.isEmpty)
    }

    @Test("No model id means the lexical retriever, which createDeepAgent supplies")
    func lexicalByDefault() {
        let inputs = RippleDeepAgent.toolSearchInputs(
            policy: .init(toolSearch: true), servers: servers, mcpTools: tools
        )
        #expect(inputs.retriever == nil)
    }

    @Test("A known model id builds a ColBERT retriever")
    func colbertWhenChosen() {
        let inputs = RippleDeepAgent.toolSearchInputs(
            policy: .init(toolSearch: true, toolSearchModel: ToolSearchModel.colbert350m8bit.repoID),
            servers: servers, mcpTools: tools
        )
        #expect(inputs.retriever is ColBERTToolRetriever)
    }

    @Test("An unrecognised model id falls back to lexical instead of failing")
    func unknownModelFallsBack() {
        // A hand-edited settings.json must not take the agent down.
        let inputs = RippleDeepAgent.toolSearchInputs(
            policy: .init(toolSearch: true, toolSearchModel: "someone/not-a-real-model"),
            servers: servers, mcpTools: tools
        )
        #expect(inputs.retriever == nil)
    }

    @Test("Every MCP tool is attributed to its server, so search results can name it")
    func toolsetsAreAttributed() {
        let toolsets = RippleDeepAgent.toolSearchInputs(
            policy: .init(toolSearch: true), servers: servers, mcpTools: tools
        ).toolsets
        #expect(toolsets.values.contains("deepwiki"))
    }
}
