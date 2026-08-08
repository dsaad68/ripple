@testable import DeepAgents
import DeepAgentsMLX
import Foundation
@testable import ripple
import Testing

/// The `/config` Context tab: the compaction threshold row, what it reports for the active model,
/// and its `settings.json` round-trip.
///
/// This is the setting that keeps a session inside what the machine can carry. Each model now
/// reports the context window its own card documents rather than a pre-shrunk one - 262,144 on the
/// qwen3_5 family - so the threshold, not a smaller declared window, is what bounds a conversation.
@MainActor
struct ConfigCompactionTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ripple-compaction-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func editorOnContextTab(window: Int? = nil) -> ConfigEditor {
        var editor = ConfigEditor(policy: .init(), contextWindowTokens: window)
        editor.tab = .context
        editor.index = editor.rows.firstIndex { $0.id == ConfigEditor.compactionRowID } ?? 0
        return editor
    }

    @Test("The Context tab carries the compaction row, cycled with space")
    func theRowCyclesThroughTheChoices() throws {
        var editor = editorOnContextTab()
        let row = try #require(editor.current)
        #expect(row.id == ConfigEditor.compactionRowID)
        #expect(editor.compactionPercent == RippleAgentConfig.defaultCompactionPercent)

        let start = editor.compactionPercent
        editor.toggle()
        #expect(editor.compactionPercent != start)
        // Cycling all the way round returns to where it started, so no value is a dead end.
        for _ in 1 ..< ConfigEditor.compactionChoices.count { editor.toggle() }
        #expect(editor.compactionPercent == start)
    }

    /// A percentage alone doesn't tell you much when windows range from 32k to 262k, so the row
    /// reports what it costs on the model actually loaded. Rounded to thousands rather than
    /// locale-grouped - a German regional format renders 52428 as "52.428", which reads as a decimal.
    @Test("The row reports the threshold in tokens for the active model")
    func theRowShowsWhatTheThresholdCosts() throws {
        var editor = editorOnContextTab(window: 262_144)
        editor.compactionPercent = 20
        #expect(try editor.stateLabel(#require(editor.current)) == "20% - 52k tokens")

        // With no model reporting a window there is nothing to multiply, so it shows the bare figure.
        var bare = editorOnContextTab()
        bare.compactionPercent = 60
        #expect(try bare.stateLabel(#require(bare.current)) == "60%")
    }

    /// The choices must reach low enough to be useful on a 262k window - at 80% that is ~210k
    /// tokens before the first compaction, which no laptop will carry.
    @Test("The choices go low enough for a very large window")
    func theChoicesReachTheLowEnd() {
        #expect(ConfigEditor.compactionChoices.min() ?? 100 <= 20)
        #expect(ConfigEditor.compactionChoices.contains(RippleAgentConfig.defaultCompactionPercent))
    }

    /// The wiring, not just the storage. Reading the setting and then building the agent with the
    /// framework default would look identical everywhere else in this file - the value has to reach
    /// the middleware that acts on it.
    @Test("The configured threshold reaches the agent's summarization middleware")
    func theThresholdReachesTheMiddleware() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        try RippleAgentConfig.saveCompactionPercent(30, workingDirectory: project)

        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "done"), workingDirectory: project
        )
        let summarization = agent.middleware.compactMap { $0 as? SummarizationMiddleware }.first
        #expect(try #require(summarization).config.triggerFraction == 0.30)
    }

    /// …and an unconfigured project gets the 80% default rather than the framework's own.
    @Test("An unconfigured project compacts at the default threshold")
    func anUnconfiguredProjectUsesTheDefault() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }

        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "done"), workingDirectory: project
        )
        let summarization = agent.middleware.compactMap { $0 as? SummarizationMiddleware }.first
        let expected = Double(RippleAgentConfig.defaultCompactionPercent) / 100
        #expect(try #require(summarization).config.triggerFraction == expected)
    }

    @Test("The threshold round-trips through settings.json")
    func theSettingRoundTrips() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }

        #expect(RippleAgentConfig.loadCompactionPercent(workingDirectory: project) == 80)
        try RippleAgentConfig.saveCompactionPercent(30, workingDirectory: project)
        #expect(RippleAgentConfig.loadCompactionPercent(workingDirectory: project) == 30)
    }
}
