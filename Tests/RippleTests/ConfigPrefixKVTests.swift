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

    @Test("The Cache tab has a Prefill cache row, on by default, toggled with space")
    func editorRowToggles() throws {
        var editor = ConfigEditor(policy: .init())
        // It lives with the limits and the usage listing now, not among the capabilities.
        editor.tab = .cache
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
        editor.tab = .cache
        editor.index = try #require(editor.rows.firstIndex { $0.id == ConfigEditor.prefixKVRowID })
        editor.toggle()
        screen.config = editor
        screen.applyConfig()
        #expect(PrefixKVStore.isEnabledOverride == false) // applied to the store immediately
        #expect(!screen.loading) // a prefix-only change does not rebuild the agent
        #expect(!RippleAgentConfig.loadPrefixKVCache(workingDirectory: project)) // and persisted
    }

    // MARK: - The Cache tab's limits and usage listing

    @Test("Space cycles the two limits, wrapping, and an unknown stored value lands on a choice")
    func limitsCycle() throws {
        var editor = ConfigEditor(policy: .init(), snapshotsPerModel: 6, maxGigabytes: 4)
        editor.tab = .cache
        editor.index = try #require(editor.rows.firstIndex { $0.id == ConfigEditor.snapshotsRowID })
        #expect(try editor.stateLabel(#require(editor.current)) == "6 per model")
        editor.toggle()
        #expect(editor.snapshotsPerModel == 8)

        editor.index = try #require(editor.rows.firstIndex { $0.id == ConfigEditor.sizeRowID })
        editor.maxGigabytes = 16
        editor.toggle()
        // Wraps to "no limit", which has to read as words rather than "0 GB".
        #expect(editor.maxGigabytes == 0)
        #expect(try editor.stateLabel(#require(editor.current)) == "no limit")

        // A hand-edited settings.json value isn't in the list; cycling must not stick on it.
        editor.snapshotsPerModel = 7
        editor.index = try #require(editor.rows.firstIndex { $0.id == ConfigEditor.snapshotsRowID })
        editor.toggle()
        #expect(ConfigEditor.snapshotChoices.contains(editor.snapshotsPerModel))
    }

    @Test("The limits round-trip through settings.json and default when absent")
    func limitsRoundTrip() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(RippleAgentConfig.loadPrefixKVSnapshots(workingDirectory: project) == 6)
        #expect(RippleAgentConfig.loadPrefixKVMaxGigabytes(workingDirectory: project) == 4)

        try RippleAgentConfig.savePrefixKVLimits(
            snapshotsPerModel: 2, maxGigabytes: 0, workingDirectory: project
        )
        #expect(RippleAgentConfig.loadPrefixKVSnapshots(workingDirectory: project) == 2)
        // A stored 0 is a deliberate "no limit", not an absent key falling back to 4.
        #expect(RippleAgentConfig.loadPrefixKVMaxGigabytes(workingDirectory: project) == 0)

        // Saving the limits must not disturb the toggle that shares the file.
        try RippleAgentConfig.savePrefixKVCache(false, workingDirectory: project)
        try RippleAgentConfig.savePrefixKVLimits(
            snapshotsPerModel: 8, maxGigabytes: 2, workingDirectory: project
        )
        #expect(!RippleAgentConfig.loadPrefixKVCache(workingDirectory: project))
        #expect(RippleAgentConfig.loadPrefixKVSnapshots(workingDirectory: project) == 8)
    }

    @Test("The usage listing shows what the store holds, and x deletes one model")
    func usageListingAndDelete() throws {
        let store = tempDir()
        defer {
            try? FileManager.default.removeItem(at: store)
            PrefixKVStore.isEnabledOverride = nil
        }
        PrefixKVStore.isEnabledOverride = true
        // Written by hand rather than through the store's own writer, which is internal to the
        // framework: this is the payload shape `inventory` attributes by.
        for (model, name) in [("vendor/alpha", "a.json"), ("vendor/beta", "b.json")] {
            let payload = ["version": "2", "model": model, "revision": "unknown", "tokens": "1,2,3"]
            try JSONEncoder().encode(payload).write(to: store.appendingPathComponent(name))
        }

        var editor = ConfigEditor(policy: .init())
        editor.tab = .cache
        editor.inventory = PrefixKVStore.inventory(directory: store, knownModelIDs: [])
        let ids = editor.rows.compactMap { editor.modelID(of: $0) }
        #expect(Set(ids) == ["vendor/alpha", "vendor/beta"])
        // The "All models" row carries the total, so the panel shows a number without a scan.
        let clear = try #require(editor.rows.first { $0.id == ConfigEditor.clearRowID })
        #expect(editor.stateLabel(clear) == ConfigEditor.size(editor.inventory.totalBytes))

        PrefixKVStore.removeAll(modelID: "vendor/alpha", directory: store, knownModelIDs: [])
        editor.inventory = PrefixKVStore.inventory(directory: store, knownModelIDs: [])
        #expect(editor.rows.compactMap { editor.modelID(of: $0) } == ["vendor/beta"])
    }

    @Test("An empty store lists the limits and nothing else")
    func emptyStoreHasNoUsageRows() {
        var editor = ConfigEditor(policy: .init())
        editor.tab = .cache
        // No "All models" row to press x on when there is nothing to delete.
        #expect(!editor.rows.contains { $0.id == ConfigEditor.clearRowID })
        #expect(editor.rows.compactMap { editor.modelID(of: $0) }.isEmpty)
        #expect(editor.rows.contains { $0.id == ConfigEditor.prefixKVRowID })
    }
}
