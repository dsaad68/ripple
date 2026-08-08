@testable import DeepAgents
@testable import DeepAgentsMLX
import Foundation
@testable import ripple
import Testing

/// Does a saved policy actually reach the agent? The persistence tests prove the file round-trips and
/// `expand()` produces the right names; this closes the last link by building the agent the way
/// `ripple chat` does and asking what it would render.
///
/// It exists because "the tiers are not applied after a restart" is indistinguishable, from the
/// outside, from "the tiers were not saved" - and the two have completely different causes.
@MainActor
struct LazyToolsWiringTests {
    /// A chat model that never runs; only the composition is under test.
    private struct InertModel: ChatModel {
        var supportsVision = false
        func makeSession() -> any ModelTurnSession { InertSession() }
    }

    private final class InertSession: ModelTurnSession {
        func nextTurn(
            messages: [AgentMessage], systemPrompt: String?, tools: [any AgentTool],
            onChunk: @escaping @Sendable (AgentStreamChunk) -> Void
        ) async throws -> AgentMessage { .ai("ok") }
    }

    /// The agent `ripple chat` would build for `policy`, with an approver present (so the gated
    /// command-line toolsets are wired, exactly as in a real session).
    private func agent(for policy: AgentToolPolicy) -> ReactAgent {
        RippleDeepAgent.make(
            textModel: InertModel(),
            approvalHandler: { _ in .approve },
            workingDirectory: FileManager.default.temporaryDirectory,
            policy: policy
        )
    }

    @Test("A restored policy hides its auxiliary toolsets from the prompt")
    func restoredPolicyIsApplied() throws {
        // The shape a real `settings.json` carries after using the Lazy Tools tab.
        let policy = AgentToolPolicy(
            toolSearch: true,
            auxiliaryMiddleware: ["apple_notes", "shell", "screenshot", "macos", "git",
                                  "clipboard", "web", "search"],
            toolSearchModel: ToolSearchModel.colbert350m8bit.repoID
        )
        let built = agent(for: policy)
        let rendered = Set(built.renderedTools.map(\.name))
        let all = Set(built.tools.map(\.name))

        // The meta-tools exist, so the middleware really was installed.
        #expect(rendered.contains("search_tools"))
        #expect(rendered.contains("run_tool"))
        // Auxiliary toolsets are dispatchable but not rendered.
        for tool in ["git_log", "grep", "fetch", "read_clipboard"] {
            #expect(all.contains(tool), "\(tool) should still be dispatchable")
            #expect(!rendered.contains(tool), "\(tool) should not be rendered")
        }
        // Core ones still are.
        #expect(rendered.contains("read_file"))
        #expect(rendered.count < all.count)
    }

    @Test("With the feature off every tool is rendered, as before")
    func featureOffRendersEverything() {
        let built = agent(for: AgentToolPolicy(auxiliaryMiddleware: ["git"]))
        let rendered = Set(built.renderedTools.map(\.name))

        #expect(rendered.contains("git_log")) // the tier is inert
        #expect(!rendered.contains("search_tools")) // and no meta-tools appear
        #expect(built.renderedTools.count == built.tools.count)
    }

    @Test("A policy loaded from disk survives all the way to the composed agent")
    func endToEndFromDisk() throws {
        // The whole chain the restart exercises: save → load → expand → make → render.
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("ripple-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try RippleAgentConfig.savePolicy(
            AgentToolPolicy(toolSearch: true, auxiliaryMiddleware: ["git"]),
            workingDirectory: project
        )

        let built = agent(for: RippleAgentConfig.loadPolicy(workingDirectory: project))
        let rendered = Set(built.renderedTools.map(\.name))
        #expect(rendered.contains("search_tools"))
        #expect(!rendered.contains("git_log"))
        #expect(built.tools.contains { $0.name == "git_log" })
    }
}
