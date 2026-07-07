@testable import DeepAgents
import DeepAgentsMLX
import Foundation
@testable import ripple
import Testing

/// The `/config` "Prefill cache" toggle: the editor row, the settings.json round-trip, and the
/// apply path that flips ``PrefixKVStore/isEnabledOverride`` without rebuilding the agent.
@MainActor
struct ConfigPrefixKVTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ripple-prefixkv-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("The Capabilities tab has a Prefill cache row, on by default, toggled with space")
    func editorRowToggles() throws {
        var editor = ConfigEditor(policy: .init())
        let index = editor.rows.firstIndex { $0.id == ConfigEditor.prefixKVRowID }
        #expect(index != nil)
        editor.index = index ?? 0
        #expect(try editor.isOn(#require(editor.current))) // on by default
        #expect(try editor.stateLabel(#require(editor.current)) == "on")
        editor.toggle()
        #expect(!editor.prefixKVCache)
        #expect(try editor.stateLabel(#require(editor.current)) == "off")
        editor.toggle()
        #expect(editor.prefixKVCache)
    }

    @Test("The setting round-trips through settings.json and defaults to on when absent")
    func settingRoundTrips() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(RippleAgentConfig.loadPrefixKVCache(workingDirectory: project)) // absent -> on
        try RippleAgentConfig.savePrefixKVCache(false, workingDirectory: project)
        #expect(!RippleAgentConfig.loadPrefixKVCache(workingDirectory: project))
        try RippleAgentConfig.savePrefixKVCache(true, workingDirectory: project)
        #expect(RippleAgentConfig.loadPrefixKVCache(workingDirectory: project))
    }

    @Test("Applying the editor persists the toggle and flips the store override, no rebuild")
    func applyFlipsStoreOverride() throws {
        let project = tempDir()
        defer {
            try? FileManager.default.removeItem(at: project)
            PrefixKVStore.isEnabledOverride = nil // don't leak into other tests
        }
        let agent = RippleDeepAgent.make(textModel: FakeChatModel(answer: "x"))
        let screen = ChatScreen(
            variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil },
            gate: ApprovalGate(), workingDirectory: project
        )
        #expect(PrefixKVStore.isEnabledOverride == true) // seeded at launch from settings
        var editor = screen.makeConfigEditor()
        editor.index = editor.rows.firstIndex { $0.id == ConfigEditor.prefixKVRowID } ?? 0
        editor.toggle()
        screen.config = editor
        screen.applyConfig()
        #expect(PrefixKVStore.isEnabledOverride == false) // applied to the store immediately
        #expect(!screen.loading) // a prefix-only change does not rebuild the agent
        #expect(!RippleAgentConfig.loadPrefixKVCache(workingDirectory: project)) // and persisted
    }
}
