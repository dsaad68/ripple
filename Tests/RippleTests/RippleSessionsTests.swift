import DeepAgents
import Foundation
@testable import ripple
import Testing

/// `ripple chat` persists each session under `~/.ripple/sessions/<id>/` (a `meta.json` + a
/// `messages.jsonl`), so it can be resumed with `ripple --resume`. These cover the file-backed
/// ``RippleSessionStore`` (round-trip, per-project listing, delete) and the project-scoped config
/// helpers (tool policy + MCP trust in `settings.json`). All use temp directories - the real
/// `~/.ripple` is never touched.
@MainActor
struct RippleSessionsTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ripple-test-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func defaultRootIsRippleSessions() {
        let root = RippleSessionStore.defaultRoot
        #expect(root.lastPathComponent == "sessions")
        #expect(root.deletingLastPathComponent().lastPathComponent == ".ripple")
    }

    @Test func sessionRoundTripPreservesCanonicalMessages() async throws {
        let root = tempDir(), project = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // An `.ai` turn with reasoning + a tool call, then the tool result that answers it - the
        // canonical, model-agnostic shape both the OpenAI and LFM2 codecs adapt at run time.
        let call = AgentToolCall(name: "search", arguments: [:])
        let history: [AgentMessage] = [
            .human("find the readme"),
            .ai("looking", toolCalls: [call], reasoning: "I should search"),
            .tool("found it", toolCallID: call.id)
        ]
        let store = RippleSessionStore(rootDirectory: root, projectPath: project, model: "lfm2")
        await store.save("s1", history)

        let loaded = await store.load("s1")
        #expect(loaded.count == 3)
        #expect(loaded.map(\.role) == [.human, .ai, .tool])
        #expect(loaded[1].reasoning == "I should search")
        #expect(loaded[1].toolCalls.first?.id == call.id)
        #expect(loaded[1].toolCalls.first?.name == "search")
        #expect(loaded[2].toolCallID == call.id)

        let meta = RippleSessionStore.meta(in: root, id: "s1")
        #expect(meta?.model == "lfm2")
        #expect(meta?.projectPath == project.standardizedFileURL.path)
        #expect(meta?.title == "find the readme")
    }

    @Test func neverSavedSessionLeavesNoDirectory() async {
        let root = tempDir(), project = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RippleSessionStore(rootDirectory: root, projectPath: project, model: "m")
        // Loading a session that was never saved must not create anything on disk.
        _ = await store.load("ghost")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ghost").path))
    }

    @Test func sessionsAreListedPerProjectMostRecentFirst() async {
        let root = tempDir(), projectA = tempDir(), projectB = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let a1 = RippleSessionStore(rootDirectory: root, projectPath: projectA, model: "m")
        await a1.save("a1", [.human("first in A")])
        let a2 = RippleSessionStore(rootDirectory: root, projectPath: projectA, model: "m")
        await a2.save("a2", [.human("second in A")])
        let b1 = RippleSessionStore(rootDirectory: root, projectPath: projectB, model: "m")
        await b1.save("b1", [.human("only in B")])

        let listed = RippleSessionStore.sessions(in: root, forProject: projectA)
        #expect(listed.map(\.id) == ["a2", "a1"]) // most-recently-saved first
        #expect(RippleSessionStore.sessions(in: root, forProject: projectB).map(\.id) == ["b1"])

        RippleSessionStore.delete(in: root, id: "a1")
        #expect(RippleSessionStore.sessions(in: root, forProject: projectA).map(\.id) == ["a2"])
    }

    @Test func toolPolicyIsSavedIntoSettingsPreservingModels() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        let settings = project.appendingPathComponent(".ripple", isDirectory: true)
            .appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // A pre-existing `models` sibling must survive the tool-policy write.
        try Data(#"{ "models": { "gpt": { "baseURL": "https://x/v1" } } }"#.utf8).write(to: settings)

        var policy = AgentToolPolicy()
        policy.disabledMiddleware = ["clipboard"]
        policy.sandbox = .failover
        try RippleAgentConfig.savePolicy(policy, workingDirectory: project)

        let root = try #require(RippleAgentConfig.readJSONObject(settings))
        #expect(root["models"] != nil) // sibling preserved
        let blob = try #require(root["toolPolicy"])
        let data = try JSONSerialization.data(withJSONObject: blob)
        let decoded = try JSONDecoder().decode(AgentToolPolicy.self, from: data)
        #expect(decoded.disabledMiddleware == ["clipboard"])
        #expect(decoded.sandbox == .failover)
    }

    @Test func mcpTrustRoundTripsThroughProjectSettings() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        // A unique name so a real `~/.ripple/settings.json` fallback can't shadow the assertion.
        let name = "srv-\(UUID().uuidString)"

        try RippleAgentConfig.saveMCPTrust(name: name, accepted: false, workingDirectory: project)
        #expect(RippleAgentConfig.loadMCPTrust(workingDirectory: project)[name]?.accepted == false)

        try RippleAgentConfig.saveMCPTrust(
            name: name, accepted: true, approval: .deny, workingDirectory: project
        )
        let trust = RippleAgentConfig.loadMCPTrust(workingDirectory: project)[name]
        #expect(trust?.accepted == true)
        #expect(trust?.approval == .deny)
    }

    // MARK: - Session store edge cases

    @Test func imageBlocksAndToolArgumentsRoundTrip() async throws {
        let root = tempDir(), project = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = AgentImage(url: URL(string: "https://example.com/a.png"))
        let inline = AgentImage(base64: "QUJD", mimeType: "image/png")
        let call = AgentToolCall(name: "search", arguments: ["q": .string("readme"), "n": .int(2)])
        let store = RippleSessionStore(rootDirectory: root, projectPath: project, model: "m")
        await store.save("img", [.human("look", images: [remote, inline]), .ai("searching", toolCalls: [call])])

        let loaded = await store.load("img")
        #expect(loaded[0].images == [remote, inline]) // url + base64/mime images survive in order
        #expect(loaded[1].toolCalls.first?.describedArguments == "n: 2, q: readme")
    }

    @Test func saveUpdatePreservesCreationAndTracksModel() async {
        let root = tempDir(), project = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = RippleSessionStore(rootDirectory: root, projectPath: project, model: "lfm2")
        await first.save("u", [.human("hi")])
        let m1 = RippleSessionStore.meta(in: root, id: "u")
        // A `/model` switch builds a new store (same id, new model): meta tracks the new model and
        // keeps the original creation time, bumping only `updatedAt`.
        let second = RippleSessionStore(rootDirectory: root, projectPath: project, model: "gpt")
        await second.save("u", [.human("hi"), .ai("a")])
        let m2 = RippleSessionStore.meta(in: root, id: "u")
        #expect(m2?.createdAt == m1?.createdAt)
        #expect(m2?.model == "gpt")
        #expect((m2?.updatedAt ?? .distantPast) >= (m1?.updatedAt ?? .distantPast))
        // A defensive empty-model store keeps the existing pinned model rather than blanking it.
        let third = RippleSessionStore(rootDirectory: root, projectPath: project, model: "")
        await third.save("u", [.human("hi"), .ai("a"), .human("more")])
        #expect(RippleSessionStore.meta(in: root, id: "u")?.model == "gpt")
    }

    @Test func sessionTitleUsesFirstHumanLineTruncatedWithFallback() async {
        let root = tempDir(), project = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        func titleFor(_ id: String, _ messages: [AgentMessage]) async -> String? {
            let store = RippleSessionStore(rootDirectory: root, projectPath: project, model: "m")
            await store.save(id, messages)
            return RippleSessionStore.meta(in: root, id: id)?.title
        }
        #expect(await titleFor("multi", [.human("first line\nsecond line")]) == "first line")
        #expect(await titleFor("long", [.human(String(repeating: "x", count: 100))])?.count == 80)
        #expect(await titleFor("nohuman", [.ai("answer")]) == "New session") // no human turn -> fallback
    }

    @Test func sessionTitleIgnoresSummaryTurns() async {
        let root = tempDir(), project = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // After a compaction the first turn is a synthetic summary (a `.human`). The title must skip it
        // and use the first real user turn, not the summary boilerplate.
        var summary = AgentMessage.human("You are continuing a conversation whose earlier messages ...")
        summary.source = AgentMessage.summarizationSource
        let history: [AgentMessage] = [summary, .ai("ack"), .human("the original question")]
        let store = RippleSessionStore(rootDirectory: root, projectPath: project, model: "m")
        await store.save("s", history)
        #expect(RippleSessionStore.meta(in: root, id: "s")?.title == "the original question")
    }

    @Test func listingSkipsStrayEntriesAndNormalizesProjectPath() async throws {
        let root = tempDir(), project = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RippleSessionStore(rootDirectory: root, projectPath: project, model: "m")
        await store.save("real", [.human("hi")])
        // A stray directory (no meta.json) and a loose file in the root must be ignored, not crash.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-session"), withIntermediateDirectories: true
        )
        try Data("junk".utf8).write(to: root.appendingPathComponent("loose.txt"))
        // A project path given in non-standardized form (a `..` segment) still matches.
        let messy = project.appendingPathComponent("x", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
        #expect(RippleSessionStore.sessions(in: root, forProject: messy).map(\.id) == ["real"])
    }

    @Test func corruptMessageLinesAreSkipped() async throws {
        let root = tempDir(), project = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RippleSessionStore(rootDirectory: root, projectPath: project, model: "m")
        await store.save("c", [.human("one"), .ai("two")])
        // Surround the valid lines with garbage; only the decodable messages should come back.
        let file = root.appendingPathComponent("c", isDirectory: true)
            .appendingPathComponent("messages.jsonl")
        let valid = try String(contentsOf: file, encoding: .utf8)
        try Data(("not json\n" + valid + "{ also bad }\n").utf8).write(to: file)
        #expect(RippleSessionStore.messages(in: root, id: "c").map(\.text) == ["one", "two"])
    }

    // MARK: - Config edge cases

    @Test func mcpTrustPreservesModelsAndOtherServers() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        let settings = project.appendingPathComponent(".ripple", isDirectory: true)
            .appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{ "models": { "gpt": {} } }"#.utf8).write(to: settings)
        let serverA = "a-\(UUID().uuidString)", serverB = "b-\(UUID().uuidString)"
        try RippleAgentConfig.saveMCPTrust(name: serverA, accepted: true, workingDirectory: project)
        try RippleAgentConfig.saveMCPTrust(name: serverB, accepted: false, workingDirectory: project)

        #expect(RippleAgentConfig.readJSONObject(settings)?["models"] != nil) // sibling preserved
        let trust = RippleAgentConfig.loadMCPTrust(workingDirectory: project)
        #expect(trust[serverA]?.accepted == true) // first server not clobbered by the second write
        #expect(trust[serverB]?.accepted == false)
    }

    @Test func mcpTrustApprovalSurvivesAReDecision() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        let name = "s-\(UUID().uuidString)"
        try RippleAgentConfig.saveMCPTrust(name: name, accepted: true, approval: .approve, workingDirectory: project)
        // Re-deciding acceptance without an approval argument must keep the prior per-server override.
        try RippleAgentConfig.saveMCPTrust(name: name, accepted: false, workingDirectory: project)
        let trust = RippleAgentConfig.loadMCPTrust(workingDirectory: project)[name]
        #expect(trust?.accepted == false)
        #expect(trust?.approval == .approve)
    }

    @Test func decodePolicyHandlesJSON5AndMissingKey() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let commented = dir.appendingPathComponent("a.json")
        try Data("""
        {
          // a hand-written comment, plus a trailing comma below
          "toolPolicy": { "disabledMiddleware": ["clipboard"], "sandbox": "off" },
        }
        """.utf8).write(to: commented)
        #expect(RippleAgentConfig.decodePolicy(commented)?.disabledMiddleware == ["clipboard"])

        let noPolicy = dir.appendingPathComponent("b.json")
        try Data(#"{ "models": {} }"#.utf8).write(to: noPolicy)
        #expect(RippleAgentConfig.decodePolicy(noPolicy) == nil)
        #expect(RippleAgentConfig.decodePolicy(dir.appendingPathComponent("missing.json")) == nil)
    }

    @Test func migratePolicyFileFoldsLegacyAndRemovesIt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("tool-policy.json")
        let settings = dir.appendingPathComponent("settings.json")
        try Data(#"{ "disabledMiddleware": ["shell"], "sandbox": "failover" }"#.utf8).write(to: legacy)
        try Data(#"{ "models": { "gpt": {} } }"#.utf8).write(to: settings)

        RippleAgentConfig.migratePolicyFile(legacy: legacy, into: settings)

        #expect(!FileManager.default.fileExists(atPath: legacy.path)) // legacy removed
        let policy = try #require(RippleAgentConfig.decodePolicy(settings))
        #expect(policy.disabledMiddleware == ["shell"])
        #expect(policy.sandbox == .failover)
        #expect(RippleAgentConfig.readJSONObject(settings)?["models"] != nil) // sibling preserved
    }

    @Test func migratePolicyFileKeepsNewerSettingsPolicy() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("tool-policy.json")
        let settings = dir.appendingPathComponent("settings.json")
        try Data(#"{ "disabledMiddleware": ["shell"] }"#.utf8).write(to: legacy)
        try Data(#"{ "toolPolicy": { "disabledMiddleware": ["clipboard"] } }"#.utf8).write(to: settings)

        RippleAgentConfig.migratePolicyFile(legacy: legacy, into: settings)

        #expect(!FileManager.default.fileExists(atPath: legacy.path)) // legacy still removed
        // The newer settings policy is not clobbered by the stale legacy file.
        #expect(RippleAgentConfig.decodePolicy(settings)?.disabledMiddleware == ["clipboard"])
    }

    // MARK: - Resume display + arg parsing

    @Test func restoreTranscriptMapsRolesFoldsToolsAndDetectsSubagent() {
        let call = AgentToolCall(name: "task", arguments: ["subagent_type": .string("vision")])
        let history: [AgentMessage] = [
            .system("system prompt"),
            .human("hello"),
            .ai("", toolCalls: [call], reasoning: "thinking"),
            .tool("the result", toolCallID: call.id),
            .ai("final", reasoning: "more")
        ]
        let messages = ChatScreen.restoreTranscript(history)
        #expect(kinds(messages) == ["user", "assistant", "assistant"]) // system + tool produce no line

        guard case .user(let text) = messages[0].kind else { Issue.record("expected a user line"); return }
        #expect(text == "hello")

        guard case .assistant(let toolTurn) = messages[1].kind else { Issue.record("expected assistant"); return }
        #expect(blockTags(toolTurn) == ["reasoning", "step"]) // empty answer adds no answer block
        if case .tool(let name, _, let output, _, let done, let subagent)? = firstStep(toolTurn)?.kind {
            #expect(name == "task")
            #expect(output == "the result") // the `.tool` result folded into its step
            #expect(done)
            #expect(subagent == "vision") // `task`'s subagent_type surfaced
        } else {
            Issue.record("expected a completed tool step")
        }

        guard case .assistant(let answerTurn) = messages[2].kind else { Issue.record("expected assistant"); return }
        #expect(blockTags(answerTurn) == ["reasoning", "answer"])
    }

    @Test func restoreTranscriptOfEmptyHistoryIsEmpty() {
        #expect(ChatScreen.restoreTranscript([]).isEmpty)
    }

    @Test func restoreTranscriptRendersSummaryAsNoteAndDropsAck() {
        // A resumed compacted session's stored history is [summary(.human), ack(.ai), real turns]. The
        // summary must render as a dim note and the synthetic ack must be dropped, so neither shows up
        // as a fake user prompt or a fake assistant reply.
        var summary = AgentMessage.human("Earlier messages summarized. A condensed summary: CONDENSED")
        summary.source = AgentMessage.summarizationSource
        var ack = AgentMessage.ai("Understood. I'll continue from the summary above.")
        ack.source = AgentMessage.summarizationSource
        let history: [AgentMessage] = [summary, ack, .human("real question"), .ai("real answer")]

        let messages = ChatScreen.restoreTranscript(history)
        #expect(kinds(messages) == ["note", "user", "assistant"]) // summary -> note, ack dropped

        guard case .note(let note) = messages[0].kind else { Issue.record("expected a note line"); return }
        #expect(note.contains("summarized"))
        guard case .user(let prompt) = messages[1].kind else { Issue.record("expected a user line"); return }
        #expect(prompt == "real question") // the summary text is NOT rendered as a user prompt
    }

    @Test func resumeRequestParsesItsForms() {
        func tag(_ request: ResumeRequest?) -> String {
            switch request {
            case .id(let value): "id:\(value)"
            case .pick: "pick"
            case nil: "nil"
            }
        }
        #expect(tag(resumeRequest(["--resume", "abc"])) == "id:abc")
        #expect(tag(resumeRequest(["--resume"])) == "pick") // no value -> pick from this project
        #expect(tag(resumeRequest(["--resume", "--model", "x"])) == "pick") // a flag isn't an id
        #expect(tag(resumeRequest(["--model", "x"])) == "nil") // flag absent
    }

    // MARK: - Second-opinion follow-ups (regression guards)

    @Test func writersPreserveSiblingsInCommentedSettings() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        let settings = project.appendingPathComponent(".ripple", isDirectory: true)
            .appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // A hand-edited JSON5 file: a comment plus a trailing comma. Strict JSON parsing would fail
        // here, so a non-tolerant writer would treat the file as empty and drop `models`.
        try Data("""
        {
          // my models
          "models": { "gpt": { "baseURL": "https://x/v1" } },
        }
        """.utf8).write(to: settings)

        let name = "s-\(UUID().uuidString)"
        try RippleAgentConfig.saveMCPTrust(name: name, accepted: true, workingDirectory: project)
        var policy = AgentToolPolicy()
        policy.disabledMiddleware = ["clipboard"]
        try RippleAgentConfig.savePolicy(policy, workingDirectory: project)

        // After both auto-writes the `models` sibling must survive, alongside the new keys.
        #expect(RippleModelConfig.loadModels(workingDirectory: project).contains { $0.name == "gpt" })
        #expect(RippleAgentConfig.loadMCPTrust(workingDirectory: project)[name]?.accepted == true)
        #expect(RippleAgentConfig.decodePolicy(settings)?.disabledMiddleware == ["clipboard"])
    }

    @Test func migratePolicyFileKeepsLegacyWhenWriteFails() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("tool-policy.json")
        try Data(#"{ "disabledMiddleware": ["shell"] }"#.utf8).write(to: legacy)
        // Force the write to fail by making the destination an existing *directory*.
        let settings = dir.appendingPathComponent("settings.json", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)

        RippleAgentConfig.migratePolicyFile(legacy: legacy, into: settings)

        #expect(FileManager.default.fileExists(atPath: legacy.path)) // not deleted -> policy not lost
    }

    @Test func projectMatchingResolvesSymlinks() async throws {
        let root = tempDir(), real = tempDir(), link = tempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: real)
            try? FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // Save with the project given as the symlink, then list with its real path: still found.
        let store = RippleSessionStore(rootDirectory: root, projectPath: link, model: "m")
        await store.save("s", [.human("hi")])
        #expect(RippleSessionStore.sessions(in: root, forProject: real).map(\.id) == ["s"])
    }

    @Test func mcpFingerprintTracksExecutionFieldsNotSecrets() {
        let base = MCPServerConfig(
            name: "foo", kind: .stdio, command: "/bin/server", args: ["--port", "1"], env: ["TOKEN": "a"]
        )
        let fingerprint = RippleAgentConfig.fingerprint(for: base)
        // Renaming, or rotating a secret in env, must NOT change the fingerprint (no spurious re-prompt).
        var renamed = base; renamed.name = "bar"
        var rotated = base; rotated.env = ["TOKEN": "b"]
        #expect(RippleAgentConfig.fingerprint(for: renamed) == fingerprint)
        #expect(RippleAgentConfig.fingerprint(for: rotated) == fingerprint)
        // Changing what runs / where it connects MUST change it.
        var newCommand = base; newCommand.command = "/bin/evil"
        var newArgs = base; newArgs.args = ["--port", "2"]
        let newTransport = MCPServerConfig(name: "foo", kind: .http, url: "https://a")
        #expect(RippleAgentConfig.fingerprint(for: newCommand) != fingerprint)
        #expect(RippleAgentConfig.fingerprint(for: newArgs) != fingerprint)
        #expect(RippleAgentConfig.fingerprint(for: newTransport) != fingerprint)
    }

    @Test func trustDecidedRequiresMatchingFingerprint() {
        let server = MCPServerConfig(name: "foo", kind: .stdio, command: "/bin/server")
        let fingerprint = RippleAgentConfig.fingerprint(for: server)
        // Unknown server -> undecided (must prompt).
        #expect(RippleAgentConfig.trustDecided(for: server, in: [:]) == nil)
        // Known with the same definition -> decided.
        let matching = ["foo": RippleAgentConfig.MCPTrust(accepted: true, approval: nil, fingerprint: fingerprint)]
        #expect(RippleAgentConfig.trustDecided(for: server, in: matching)?.accepted == true)
        // Known but the definition changed (or a legacy nil-fingerprint entry) -> undecided (re-prompt).
        let stale = ["foo": RippleAgentConfig.MCPTrust(accepted: true, approval: nil, fingerprint: "stale")]
        let legacy = ["foo": RippleAgentConfig.MCPTrust(accepted: true, approval: nil, fingerprint: nil)]
        #expect(RippleAgentConfig.trustDecided(for: server, in: stale) == nil)
        #expect(RippleAgentConfig.trustDecided(for: server, in: legacy) == nil)
    }

    @Test func mcpTrustPersistsFingerprint() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        let name = "s-\(UUID().uuidString)"
        try RippleAgentConfig.saveMCPTrust(
            name: name, accepted: true, fingerprint: "abc123", workingDirectory: project
        )
        #expect(RippleAgentConfig.loadMCPTrust(workingDirectory: project)[name]?.fingerprint == "abc123")
    }

    // MARK: - Per-project selected model

    @Test func selectedModelRoundTripsAndPreservesSiblings() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        let settings = project.appendingPathComponent(".ripple", isDirectory: true)
            .appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{ "models": { "gpt": {} } }"#.utf8).write(to: settings)

        #expect(RippleAgentConfig.loadSelectedModel(workingDirectory: project) == nil) // unset
        try RippleAgentConfig.saveSelectedModel("LiquidAI/Some-Model", workingDirectory: project)
        #expect(RippleAgentConfig.loadSelectedModel(workingDirectory: project) == "LiquidAI/Some-Model")
        #expect(RippleAgentConfig.readJSONObject(settings)?["models"] != nil) // sibling preserved
    }

    @Test func isKnownModelAcceptsKnownAndRejectsStale() throws {
        let known = try #require(DeepAgentVariant.all.first?.textModelID) // a built-in on-device planner
        #expect(RippleModelResolution.isKnownModel(known, remote: []))
        #expect(!RippleModelResolution.isKnownModel("definitely-not-a-real-model-xyz", remote: [])) // stale -> ignored
        let remote = OpenAIModelConfig(
            name: "my-remote", baseURL: "https://x/v1", model: "m", apiKey: nil,
            vision: false, reasoning: false, temperature: nil, maxTokens: nil, topP: nil
        )
        #expect(RippleModelResolution.isKnownModel("my-remote", remote: [remote])) // registered remote by name
    }

    // MARK: - Helpers

    private func kinds(_ messages: [Message]) -> [String] {
        messages.map {
            switch $0.kind {
            case .user: "user"
            case .assistant: "assistant"
            case .bang: "bang"
            case .note: "note"
            }
        }
    }

    private func blockTags(_ assistant: Assistant) -> [String] {
        assistant.blocks.map {
            switch $0 {
            case .reasoning: "reasoning"
            case .step: "step"
            case .answer: "answer"
            }
        }
    }

    private func firstStep(_ assistant: Assistant) -> Step? {
        for block in assistant.blocks { if case .step(let step) = block { return step } }
        return nil
    }
}
