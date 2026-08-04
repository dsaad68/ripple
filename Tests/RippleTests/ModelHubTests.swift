@testable import DeepAgents
import DeepAgentsMLX
import Foundation
@testable import ripple
import Testing

/// The unified `/model` overlay's Select tab (``ModelSelectEditor``) and the shared
/// ``RippleModelResolution`` it persists into: a main agent / vision can be a downloaded local model
/// or a registered remote one, and the configured-vision rule (incl. the "a remote vision has nothing
/// to download" guard) lives in one place.
@MainActor
struct ModelHubTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ripple-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func remote(_ name: String, vision: Bool) -> OpenAIModelConfig {
        OpenAIModelConfig(
            name: name, baseURL: "https://h/v1", model: "m", apiKey: nil,
            vision: vision, reasoning: false, temperature: nil, maxTokens: nil, topP: nil
        )
    }

    private func editor(mainAgent: String = "local-main", vision: String = "", remote: [OpenAIModelConfig]) -> ModelSelectEditor {
        ModelSelectEditor(
            mainAgent: mainAgent, vision: vision,
            mainAgentIdleMinutes: 10, visionIdleMinutes: 10, remote: remote
        )
    }

    @Test("The main-agent options include registered remote models and the current selection")
    func mainAgentOptionsIncludeRemote() {
        let editor = editor(mainAgent: "local-main", remote: [remote("my-remote", vision: false)])
        let options = editor.mainAgentOptions
        #expect(options.contains("my-remote")) // a remote model can back the main agent
        #expect(options.contains("local-main")) // the current selection is always offered
    }

    @Test("The vision options put Off first, include remote vision models, and skip text-only remotes")
    func visionOptionsIncludeRemoteVisionOnly() {
        let editor = editor(remote: [remote("vision-remote", vision: true), remote("text-remote", vision: false)])
        let options = editor.visionOptions
        #expect(options.first == "") // "Off" leads the list
        #expect(options.contains("vision-remote"))
        #expect(!options.contains("text-remote")) // a text-only remote can't be the vision model
    }

    @Test("A remote model's picker label is tagged remote")
    func remoteModelLabelTagged() {
        let editor = editor(remote: [remote("my-remote", vision: false)])
        #expect(editor.modelLabel("my-remote").contains("remote"))
    }

    @Test("Committing a picker choice updates the field and flags the change")
    func commitPickingTracksChange() {
        var editor = editor(mainAgent: "local-main", remote: [remote("my-remote", vision: false)])
        #expect(!editor.mainAgentChanged)
        editor.index = 0 // the Main agent row
        editor.beginPicking()
        // Move to the remote option, then commit it.
        let remoteIndex = editor.mainAgentOptions.firstIndex(of: "my-remote") ?? 0
        editor.picking?.index = remoteIndex
        editor.commitPicking()
        #expect(editor.mainAgentID == "my-remote")
        #expect(editor.mainAgentChanged)
    }

    @Test("Idle changes are tracked independently of the model selection")
    func idleChangeTracked() {
        var editor = editor(remote: [])
        #expect(!editor.idleChanged)
        editor.mainAgentIdleMinutes = 0
        #expect(editor.idleChanged)
        #expect(!editor.mainAgentChanged)
    }

    // MARK: - RippleModelResolution

    @Test("configuredVisionID returns the saved vision model, else the variant default")
    func configuredVisionIDPrefersSaved() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        let variant = try #require(DeepAgentVariant.all.first { $0.id == "mispher.deepagent" })

        #expect(RippleModelResolution.configuredVisionID(variant, workingDirectory: project) == variant.visionModelID)
        try RippleAgentConfig.saveVisionModel("vendor/my-vlm", workingDirectory: project)
        #expect(RippleModelResolution.configuredVisionID(variant, workingDirectory: project) == "vendor/my-vlm")
    }

    @Test("requiredModelIDs downloads a local vision model but skips a remote one")
    func requiredModelIDsSkipsRemoteVision() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        let variant = try #require(DeepAgentVariant.all.first { $0.id == "mispher.deepagent" })

        // A remote vision id isn't in the catalog, so it has nothing on disk to fetch.
        try RippleAgentConfig.saveVisionModel("my-remote", workingDirectory: project)
        #expect(RippleModelResolution.requiredModelIDs(variant, workingDirectory: project) == [variant.textModelID])

        // A local catalog vision id is listed for download alongside the planner.
        try RippleAgentConfig.saveVisionModel(variant.visionModelID, workingDirectory: project)
        let ids = RippleModelResolution.requiredModelIDs(variant, workingDirectory: project)
        #expect(ids.contains(variant.textModelID))
        #expect(ids.contains(variant.visionModelID))
    }

    @Test("requiredModelIDs is empty for a remote variant")
    func requiredModelIDsEmptyForRemote() {
        let variant = DeepAgentVariant.remote(remote("my-remote", vision: false))
        #expect(RippleModelResolution.requiredModelIDs(variant, workingDirectory: tempDir()).isEmpty)
    }

    // MARK: - Stale-selection guard (apply on close)

    private func makeScreen(workingDirectory: URL) -> ChatScreen {
        let agent = RippleDeepAgent.make(textModel: FakeChatModel(answer: "x"))
        return ChatScreen(
            variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil },
            gate: ApprovalGate(), variants: DeepAgentVariant.all, workingDirectory: workingDirectory
        )
    }

    @Test("mainAgentSelectable accepts a registered remote, rejects a model removed after it was picked")
    func mainAgentSelectableDiscriminates() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        try RippleModelConfig.saveModelEntry(
            name: "my-remote", ["baseURL": "https://h/v1", "model": "m", "apiKey": "$K"],
            to: RippleAgentConfig.projectSettingsURL(workingDirectory: project)
        )
        let screen = makeScreen(workingDirectory: project)
        #expect(screen.mainAgentSelectable("my-remote")) // a currently-registered remote is selectable
        #expect(!screen.mainAgentSelectable("removed/remote-llm")) // removed: not remote, not downloaded
    }

    @Test("Closing the hub on a removed main agent leaves the live planner unchanged (no silent switch)")
    func staleMainAgentNotSwitched() {
        let screen = makeScreen(workingDirectory: tempDir())
        let original = screen.variant.id
        screen.openModelHub()
        screen.modelHub?.select.mainAgentID = "removed/remote-llm" // picked, then removed elsewhere
        #expect(screen.modelHub?.select.mainAgentChanged == true)
        screen.closeModelHub()
        #expect(!screen.loading) // switchToVariant was not attempted for the stale selection
        #expect(screen.variant.id == original) // the live planner is untouched
    }

    // MARK: - Local-tab download feedback

    @Test("The Local tab draws the in-flight download bar itself (the overlay block is hidden in a menu)")
    func localTabShowsDownloadProgress() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        let screen = makeScreen(workingDirectory: project)
        screen.contentHeight = 20 // normally set by render(); drawBrowserList sizes its body from it
        screen.openModelHub(tab: .local)
        let model = MlxModel.catalog[0]
        screen.downloading = DownloadProgress(label: model.shortName, fraction: 0.42, modelID: model.id)
        let browser = try #require(screen.toolsBrowser)
        let raw = screen.drawBrowserList(browser, width: 100, top: 2)
        // The footer hint colors each token separately, so strip the ANSI escapes before matching.
        let frame = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        #expect(frame.contains("downloading")) // the live bar renders inside the panel
        #expect(frame.contains("42%")) // with the blended fraction (bar line and/or row marker)
        #expect(frame.contains("esc cancel download")) // the footer says esc cancels, not closes
        #expect(!frame.contains("x remove")) // the gated-off keys aren't advertised mid-download
    }

    @Test("A stale / removed vision model degrades to vision-off instead of failing the agent build")
    func staleVisionDegradesToOff() throws {
        let project = tempDir()
        defer { try? FileManager.default.removeItem(at: project) }
        let variant = try #require(DeepAgentVariant.all.first { $0.id == "mispher.deepagent" })

        // A configured vision id that's neither a catalog model nor a registered remote - e.g. an
        // OpenRouter model that was picked as the vision model and later removed on the Remote tab.
        try RippleAgentConfig.saveVisionModel("removed/remote-vlm", workingDirectory: project)
        let models = RippleModelResolution.deepAgentModels(
            choice: variant, manager: MlxModelLoader(), workingDirectory: project, remote: []
        )
        #expect(models != nil) // the planner still resolves, so `ripple chat` still starts
        #expect(models?.vision == nil) // the unresolvable vision degrades to off, not a fatal build error
    }
}
