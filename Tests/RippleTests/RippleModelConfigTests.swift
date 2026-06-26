import DeepAgents
import DeepAgentsAnthropic
@testable import DeepAgentsOpenAI
import Foundation
@testable import ripple
import Testing

/// The `~/.ripple/settings.json` loader: named-map decoding, environment expansion of the secret base
/// URL / api key (both `${VAR}` and bare `$VAR`), defaults, and the `OpenAIChatModel` factory. Pure
/// parsing - no network.
struct RippleModelConfigTests {
    @Test func parsesNamedModelsWithDefaultsAndExpansion() {
        withEnvironment(["RIPPLE_TEST_KEY": "secret-123"]) {
            let json = """
            { "models": {
                "my-gpt": {
                    "baseURL": "https://api.example.com/v1",
                    "model": "gpt-4o",
                    "apiKey": "${RIPPLE_TEST_KEY}",
                    "vision": true,
                    "temperature": 0.2,
                    "maxTokens": 4096
                },
                "bare": { "baseURL": "https://host/v1" }
            } }
            """
            let configs = RippleModelConfig.parse(Data(json.utf8))
            #expect(configs.map(\.name) == ["bare", "my-gpt"]) // sorted by name for a stable order

            let gpt = configs.first { $0.name == "my-gpt" }
            #expect(gpt?.baseURL == "https://api.example.com/v1")
            #expect(gpt?.model == "gpt-4o")
            #expect(gpt?.apiKey == "secret-123") // ${RIPPLE_TEST_KEY} expanded from the environment
            #expect(gpt?.vision == true)
            #expect(gpt?.temperature == 0.2)
            #expect(gpt?.maxTokens == 4096)
            #expect(gpt?.host == "api.example.com")

            let bare = configs.first { $0.name == "bare" }
            #expect(bare?.model == "bare") // model defaults to the selection name
            #expect(bare?.vision == false)
            #expect(bare?.apiKey == nil)
        }
    }

    @Test func chatModelBuildsFromConfig() throws {
        let config = OpenAIModelConfig(
            name: "x", baseURL: "https://api.example.com/v1", model: "gpt-4o",
            apiKey: "k", vision: true, reasoning: false, temperature: nil, maxTokens: nil, topP: nil
        )
        let model = try #require(config.chatModel())
        #expect(model.supportsVision)
        #expect(model.modelID == "x")
    }

    @Test func bareDollarEnvVarIsResolved() {
        withEnvironment(["RIPPLE_TEST_BARE_KEY": "bare-secret"]) {
            let json = """
            { "models": { "g": { "baseURL": "https://h/v1", "apiKey": "$RIPPLE_TEST_BARE_KEY" } } }
            """
            let config = RippleModelConfig.parse(Data(json.utf8)).first
            #expect(config?.apiKey == "bare-secret") // $NAME read from the environment
        }
    }

    @Test func unsetBareEnvVarResolvesEmptyAndLiteralDollarIsKept() {
        withEnvironment(["RIPPLE_TEST_MISSING": nil]) {
            let json = """
            { "models": {
                "missing": { "baseURL": "https://h/v1", "apiKey": "$RIPPLE_TEST_MISSING" },
                "literal": { "baseURL": "https://h/v1", "apiKey": "sk-$literal-not-a-ref!" }
            } }
            """
            let configs = RippleModelConfig.parse(Data(json.utf8))
            #expect(configs.first { $0.name == "missing" }?.apiKey == "") // unset -> empty, no auth header
            // A value that isn't a bare `$NAME` (extra characters) is left untouched.
            #expect(configs.first { $0.name == "literal" }?.apiKey == "sk-$literal-not-a-ref!")
        }
    }

    @Test func malformedJSONYieldsNoModels() {
        #expect(RippleModelConfig.parse(Data("not json".utf8)).isEmpty)
    }

    @Test func emptyScaffoldYieldsNoModels() {
        // The shape `ensureUserFile` writes on first run: a valid file with no models registered.
        #expect(RippleModelConfig.parse(Data("{ \"models\": {} }".utf8)).isEmpty)
    }

    @Test func parseToleratesJSON5Comments() {
        // A hand-edited file may carry `//` comments; the loader must tolerate them (JSON5).
        let json = """
        // a leading comment
        { "models": {
            // an inline note
            "g": { "baseURL": "https://h/v1", "model": "m" }
        } }
        """
        #expect(RippleModelConfig.parse(Data(json.utf8)).map(\.name) == ["g"])
    }

    @Test func saveAndRemoveModelEntryPreservesSiblings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ripple-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed a file with one hand-written model carrying a ${VAR} placeholder.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ \"models\": { \"keep\": { \"baseURL\": \"https://h/v1\", \"apiKey\": \"${KEEP_KEY}\" } } }".utf8)
            .write(to: url)

        // Add an OpenRouter-style entry alongside it.
        try RippleModelConfig.saveModelEntry(name: "meta/llama:free", [
            "baseURL": "${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}",
            "model": "meta/llama:free",
            "apiKey": "$OPENROUTER_API_KEY",
            "vision": true
        ], to: url)

        let afterAdd = RippleModelConfig.loadModels(sources: [url])
        #expect(afterAdd.map(\.name) == ["keep", "meta/llama:free"]) // sorted; sibling preserved
        let added = afterAdd.first { $0.name == "meta/llama:free" }
        #expect(added?.model == "meta/llama:free")
        #expect(added?.vision == true)
        // The sibling's raw ${KEEP_KEY} placeholder survives verbatim (not expanded on write).
        #expect(try String(contentsOf: url, encoding: .utf8).contains("${KEEP_KEY}"))

        // Remove the added entry; the sibling stays, and removing a missing one is a no-op.
        #expect(try RippleModelConfig.removeModelEntry(name: "meta/llama:free", from: url))
        #expect(RippleModelConfig.loadModels(sources: [url]).map(\.name) == ["keep"])
        #expect(try RippleModelConfig.removeModelEntry(name: "nope", from: url) == false)
    }

    @Test func remoteVariantIsTextOnlyWithoutVision() {
        let textOnly = OpenAIModelConfig(
            name: "t", baseURL: "https://h/v1", model: "m",
            apiKey: nil, vision: false, reasoning: false, temperature: nil, maxTokens: nil, topP: nil
        )
        let variant = DeepAgentVariant.remote(textOnly)
        #expect(variant.isRemote)
        #expect(variant.visionModelID.isEmpty) // no vision subagent
        #expect(variant.modelIDs.isEmpty) // nothing on disk to fetch
    }

    @Test func reasoningFlagDefaultsFalseAndParses() {
        let json = """
        { "models": {
            "with": { "baseURL": "https://h/v1", "reasoning": true },
            "without": { "baseURL": "https://h/v1" }
        } }
        """
        let configs = RippleModelConfig.parse(Data(json.utf8))
        #expect(configs.first { $0.name == "with" }?.reasoning == true)
        #expect(configs.first { $0.name == "without" }?.reasoning == false) // absent → false
    }

    @Test func chatModelCarriesReasoningFlag() throws {
        let on = OpenAIModelConfig(
            name: "x", baseURL: "https://h/v1", model: "m",
            apiKey: nil, vision: false, reasoning: true, temperature: nil, maxTokens: nil, topP: nil
        )
        // config flag reaches the built ChatModel (cast back to the concrete OpenAI type)
        #expect(try #require(on.chatModel() as? OpenAIChatModel).reasoning)
        let off = OpenAIModelConfig(
            name: "x", baseURL: "https://h/v1", model: "m",
            apiKey: nil, vision: false, reasoning: false, temperature: nil, maxTokens: nil, topP: nil
        )
        #expect(try !(#require(off.chatModel() as? OpenAIChatModel).reasoning))
    }

    @Test func remoteTagsReflectModelHostAndCapabilities() {
        let full = OpenAIModelConfig(
            name: "x", baseURL: "https://api.example.com/v1", model: "gpt-4o",
            apiKey: nil, vision: true, reasoning: true, temperature: nil, maxTokens: nil, topP: nil
        )
        #expect(RippleModelCommand.remoteTags(full) == ["gpt-4o", "api.example.com", "vision", "reasoning"])
        let bare = OpenAIModelConfig(
            name: "x", baseURL: "https://api.example.com/v1", model: "gpt-4o",
            apiKey: nil, vision: false, reasoning: false, temperature: nil, maxTokens: nil, topP: nil
        )
        #expect(RippleModelCommand.remoteTags(bare) == ["gpt-4o", "api.example.com"])
    }

    // MARK: - Multi-provider

    @Test func providerAliasesDecode() {
        #expect(RemoteProvider("claude") == .anthropic)
        #expect(RemoteProvider("aws-bedrock") == .bedrock)
        #expect(RemoteProvider("azure-openai") == .azure)
        #expect(RemoteProvider(nil) == .openai)
        #expect(RemoteProvider("nonsense") == .openai) // unrecognized -> the OpenAI default
    }

    @Test func parsesAnthropicProviderAndBuildsAnthropicModel() throws {
        let json = """
        { "models": { "claude": {
            "provider": "anthropic", "model": "claude-opus-4-8", "apiKey": "k",
            "anthropicVersion": "2024-10-01", "beta": ["feature-x"], "maxTokens": 2048
        } } }
        """
        let config = try #require(RippleModelConfig.parse(Data(json.utf8)).first)
        #expect(config.provider == .anthropic)
        #expect(config.anthropicVersion == "2024-10-01")
        #expect(config.betaHeaders == ["feature-x"])
        #expect(config.maxTokens == 2048)
        #expect(try #require(config.chatModel()) is AnthropicChatModel)
    }

    @Test func parsesAzureProviderAndBuildsOpenAIModel() throws {
        let json = """
        { "models": { "az": {
            "provider": "azure", "baseURL": "https://r.openai.azure.com",
            "azureDeployment": "dep", "apiVersion": "2024-10-21", "apiKey": "k", "model": "gpt-4o"
        } } }
        """
        let config = try #require(RippleModelConfig.parse(Data(json.utf8)).first)
        #expect(config.provider == .azure)
        #expect(config.azureDeployment == "dep")
        #expect(config.apiVersion == "2024-10-21")
        #expect(try #require(config.chatModel()) is OpenAIChatModel) // Azure rides the OpenAI adapter
    }

    @Test func bedrockChatModelRequiresAWSCredentials() {
        let config = OpenAIModelConfig(
            name: "b", baseURL: "", model: "anthropic.claude", apiKey: nil, vision: false,
            reasoning: false, temperature: nil, maxTokens: nil, topP: nil,
            provider: .bedrock, region: "us-east-1"
        )
        withEnvironment(["AWS_ACCESS_KEY_ID": nil, "AWS_SECRET_ACCESS_KEY": nil]) {
            #expect(config.chatModel() == nil) // no AWS creds in the environment
        }
        withEnvironment(["AWS_ACCESS_KEY_ID": "AK", "AWS_SECRET_ACCESS_KEY": "SK"]) {
            #expect((config.chatModel() as? BedrockChatModel) != nil)
        }
    }
}
