import DeepAgents
import DeepAgentsAnthropic
import DeepAgentsOpenAI
import Foundation

/// The cloud provider a registered model targets. Decoded from the `provider` field (case- and
/// alias-insensitive); absent or unrecognized falls back to `.openai` (the original behavior).
enum RemoteProvider: String, Sendable, Hashable {
    case openai
    case azure
    case anthropic
    case bedrock

    init(_ raw: String?) {
        switch raw?.lowercased() {
        case "azure", "azure-openai", "azureopenai": self = .azure
        case "anthropic", "claude": self = .anthropic
        case "bedrock", "aws", "aws-bedrock": self = .bedrock
        default: self = .openai
        }
    }
}

/// A user-registered remote model, loaded from `settings.json` so `ripple` can drive the deep agent
/// with a cloud endpoint instead of an on-device MLX model. The `provider` field selects the wire
/// protocol: an OpenAI-compatible endpoint (the default), Azure OpenAI, the Anthropic Messages API,
/// or Anthropic on AWS Bedrock. The `name` is the selection id - `ripple chat --model <name>`.
struct OpenAIModelConfig: Sendable, Hashable {
    /// Selection id (the `--model` value / `/model` picker entry); also the logged model id.
    let name: String
    /// The API root. For OpenAI it holds `/chat/completions` (commonly ends in `/v1`); for Azure
    /// it's the resource root; for Anthropic the API root (defaults to `https://api.anthropic.com`);
    /// unused for Bedrock (the endpoint derives from the region).
    let baseURL: String
    /// The upstream model name sent in each request (defaults to `name` when omitted). For Bedrock,
    /// the Bedrock model or cross-region inference-profile id.
    let model: String
    let apiKey: String?
    /// When true the same remote model also backs the `vision` subagent; otherwise the agent runs
    /// text-only (no vision subagent).
    let vision: Bool
    /// When true, ask the endpoint to stream chain-of-thought (OpenRouter's `reasoning` param) and
    /// surface it in the thinking disclosure.
    let reasoning: Bool
    let temperature: Double?
    let maxTokens: Int?
    let topP: Double?
    /// The cloud provider / wire protocol. Trailing defaulted fields keep the memberwise init
    /// source-compatible with existing OpenAI call sites.
    var provider: RemoteProvider = .openai
    /// Anthropic `anthropic-version` header (defaults to `2023-06-01`).
    var anthropicVersion: String?
    /// Anthropic `anthropic-beta` feature flags.
    var betaHeaders: [String] = []
    /// Azure deployment name (defaults to `model`).
    var azureDeployment: String?
    /// Azure `api-version` query value (defaults to a recent GA version).
    var apiVersion: String?
    /// AWS region for Bedrock (falls back to `AWS_REGION` / `AWS_DEFAULT_REGION`, then `us-east-1`).
    var region: String?
    /// The model's context window in tokens, for summarization's 85% trigger and the context meter.
    /// Optional in `settings.json`; when omitted it's inferred from the provider + model id
    /// (see ``resolvedContextWindow``). Trailing/defaulted to keep the memberwise init compatible.
    var contextWindow: Int?

    /// The host shown in `ripple model list` (e.g. `api.openai.com`).
    var host: String { URL(string: baseURL)?.host() ?? baseURL }

    /// The context window to advertise to the agent: the configured value, else a per-provider /
    /// per-model estimate so a cloud model doesn't fall back to the small on-device default.
    var resolvedContextWindow: Int? {
        if let contextWindow { return contextWindow }
        return Self.inferContextWindow(provider: provider, model: model, betaHeaders: betaHeaders)
    }

    /// A best-effort context window for a known provider/model when `settings.json` doesn't say.
    /// Deliberately conservative and easy to override per model.
    static func inferContextWindow(provider: RemoteProvider, model: String, betaHeaders: [String]) -> Int? {
        let id = model.lowercased()
        switch provider {
        case .anthropic, .bedrock:
            let oneMillion = id.contains("1m") || betaHeaders.contains { $0.lowercased().contains("1m") }
            return oneMillion ? 1_000_000 : 200_000
        case .openai, .azure:
            if id.contains("gpt-4o") || id.contains("gpt-4.1") || id.contains("gpt-4-turbo") { return 128_000 }
            if id.contains("o1") || id.contains("o3") || id.contains("o4") { return 200_000 }
            if id.contains("gpt-3.5") { return 16385 }
            if id.contains("gpt-4") { return 8192 }
            return 128_000
        }
    }

    /// Build the backend `ChatModel` for this config, dispatching on `provider`. Nil when a required
    /// value is missing (a malformed base URL, or absent AWS credentials for Bedrock).
    func chatModel() -> (any ChatModel)? {
        switch provider {
        case .openai: return openAIModel(endpointStyle: .standard, auth: .bearer)
        case .azure:
            return openAIModel(
                endpointStyle: .azure(deployment: azureDeployment ?? model, apiVersion: apiVersion ?? "2024-10-21"),
                auth: .apiKey
            )
        case .anthropic: return anthropicModel()
        case .bedrock: return bedrockModel()
        }
    }

    private func openAIModel(endpointStyle: OpenAIEndpointStyle, auth: OpenAIAuthStyle) -> OpenAIChatModel? {
        guard let url = URL(string: baseURL) else { return nil }
        return OpenAIChatModel(
            baseURL: url, model: model, apiKey: apiKey, supportsVision: vision, modelID: name,
            contextWindowTokens: resolvedContextWindow,
            parameters: OpenAIGenerateParameters(temperature: temperature, topP: topP, maxTokens: maxTokens),
            reasoning: reasoning, auth: auth, endpointStyle: endpointStyle
        )
    }

    private func anthropicModel() -> AnthropicChatModel? {
        guard let url = URL(string: baseURL.isEmpty ? "https://api.anthropic.com" : baseURL) else { return nil }
        return AnthropicChatModel(
            baseURL: url, model: model, apiKey: apiKey, supportsVision: vision, modelID: name,
            contextWindowTokens: resolvedContextWindow,
            parameters: AnthropicGenerateParameters(maxTokens: maxTokens, temperature: temperature, topP: topP),
            anthropicVersion: anthropicVersion ?? "2023-06-01", betaHeaders: betaHeaders
        )
    }

    private func bedrockModel() -> BedrockChatModel? {
        guard let auth = BedrockAuth.resolve(bearerToken: apiKey) else { return nil }
        var endpointOverride: String?
        if case .bearerToken = auth {
            // Bearer-token auth needs an explicit endpoint; SigV4 derives it from the region.
            guard !baseURL.isEmpty else { return nil }
            endpointOverride = baseURL
        }
        return BedrockChatModel(
            region: resolvedRegion, model: model, auth: auth, baseURL: endpointOverride,
            supportsVision: vision, modelID: name, contextWindowTokens: resolvedContextWindow,
            parameters: AnthropicGenerateParameters(maxTokens: maxTokens, temperature: temperature, topP: topP)
        )
    }

    /// The Bedrock region: the configured value, else `AWS_REGION` / `AWS_DEFAULT_REGION`, else a default.
    private var resolvedRegion: String {
        if let region, !region.isEmpty { return region }
        let env = ProcessInfo.processInfo.environment
        return env["AWS_REGION"] ?? env["AWS_DEFAULT_REGION"] ?? "us-east-1"
    }
}

/// Loads the user's OpenAI-compatible models from JSON, mirroring ``RippleAgentConfig``'s
/// `mcp.json` convention: merged from `<project>/.ripple/settings.json` then `~/.ripple/settings.json`
/// (first definition of a given name wins). The `apiKey`, `baseURL`, and `model` fields are
/// resolved against the process environment, so a secret stays out of the file - reference it as
/// the bare `$OPENAI_API_KEY`, or with the brace forms `${OPENAI_API_KEY}` / `${VAR:-default}`.
///
/// The optional `provider` field selects the wire protocol (`openai` is the default): `openai`,
/// `azure`, `anthropic`, or `bedrock`. OpenAI-native works today by pointing `baseURL` at
/// `https://api.openai.com/v1`. Bedrock authenticates with a bearer token - an Amazon Bedrock API key
/// in `apiKey` (or the `AWS_BEARER_TOKEN_BEDROCK` env var) plus a verbatim `baseURL` - or, when no
/// token is set, AWS SigV4 from the standard `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
/// `AWS_SESSION_TOKEN` environment variables.
///
/// ```json
/// { "models": {
///     "gpt-4o":      { "provider": "openai",    "baseURL": "${OPENAI_BASE_URL:-https://api.openai.com/v1}",
///                      "model": "gpt-4o", "apiKey": "$OPENAI_API_KEY", "vision": true },
///     "claude":      { "provider": "anthropic", "model": "claude-opus-4-8",
///                      "apiKey": "$ANTHROPIC_API_KEY", "maxTokens": 4096, "vision": true },
///     "claude-aws":  { "provider": "bedrock",   "region": "$AWS_REGION",
///                      "model": "us.anthropic.claude-opus-4-8", "vision": true },
///     "claude-key":  { "provider": "bedrock",   "region": "us-east-1", "apiKey": "$AWS_BEARER_TOKEN_BEDROCK",
///                      "baseURL": "https://bedrock-runtime.us-east-1.amazonaws.com",
///                      "model": "us.anthropic.claude-opus-4-8", "vision": true },
///     "azure-gpt4o": { "provider": "azure",     "baseURL": "$AZURE_OPENAI_ENDPOINT",
///                      "azureDeployment": "gpt-4o", "apiVersion": "2024-10-21", "apiKey": "$AZURE_OPENAI_KEY" }
/// } }
/// ```
enum RippleModelConfig {
    static func loadModels(workingDirectory: URL) -> [OpenAIModelConfig] {
        loadModels(sources: sourceURLs(workingDirectory: workingDirectory))
    }

    /// The two config sources, in load/merge order: the project file, then the global fallback.
    static func sourceURLs(workingDirectory: URL) -> [URL] {
        [
            workingDirectory.appendingPathComponent(".ripple", isDirectory: true)
                .appendingPathComponent("settings.json"),
            userFileURL
        ]
    }

    /// `~/.ripple/settings.json` - the global fallback file.
    static var userFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ripple", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// Create an empty `~/.ripple/settings.json` the first time `ripple` runs, so there's a place to
    /// register a remote model (see ``OpenAIModelConfig`` for the entry shape). Best-effort: a no-op
    /// when the file already exists, and it never fails the launch if the write doesn't go through.
    static func ensureUserFile() {
        let url = userFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data(template.utf8).write(to: url, options: .atomic)
    }

    /// The scaffold written to a missing `~/.ripple/settings.json`: an empty `models` object.
    private static let template = """
    {
      "models": {}
    }

    """

    /// Merge the model files at `sources`, in order, first definition of a name winning. (Separated
    /// from the default source list so tests can supply their own without the real
    /// `~/.ripple/settings.json` leaking in.)
    static func loadModels(sources: [URL]) -> [OpenAIModelConfig] {
        var seen: Set<String> = []
        var merged: [OpenAIModelConfig] = []
        for url in sources {
            guard let data = try? Data(contentsOf: url) else { continue }
            for config in parse(data) where seen.insert(config.name).inserted {
                merged.append(config)
            }
        }
        return merged
    }

    // MARK: - Writing models (the `/models-config` OpenRouter tab)

    /// Insert (or replace) the raw `entry` for model `name` in the `models` object of the file at
    /// `url`, then atomic-write it pretty-printed. Every other model is preserved verbatim - we mutate
    /// the file's parsed JSON object directly (reusing ``RippleAgentConfig``'s helpers) rather than
    /// re-encoding `[OpenAIModelConfig]`, so untouched siblings keep their `${VAR}` placeholders.
    /// Creates `.ripple/` if needed (mirrors ``RippleAgentConfig/saveServerEntry(name:_:to:)``).
    static func saveModelEntry(name: String, _ entry: [String: Any], to url: URL) throws {
        var root = RippleAgentConfig.readJSONObject(url) ?? [:]
        var models = root["models"] as? [String: Any] ?? [:]
        models[name] = entry
        root["models"] = models
        try RippleAgentConfig.writeJSONObject(root, to: url)
    }

    /// Remove model `name` from the `models` object of the file at `url`, preserving every other
    /// model verbatim. Returns `false` (writing nothing) when the file has no such model.
    @discardableResult
    static func removeModelEntry(name: String, from url: URL) throws -> Bool {
        guard var root = RippleAgentConfig.readJSONObject(url),
              var models = root["models"] as? [String: Any], models[name] != nil
        else { return false }
        models[name] = nil
        root["models"] = models
        try RippleAgentConfig.writeJSONObject(root, to: url)
        return true
    }

    /// Parse a `{ "models": { ... } }` document into configs (sorted by name for a stable order),
    /// expanding environment references. JSON5 is allowed so a hand-edited file's `//` comments and
    /// trailing commas are tolerated. Returns `[]` on malformed input.
    static func parse(_ data: Data) -> [OpenAIModelConfig] {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        guard let file = try? decoder.decode(ModelsFile.self, from: data) else { return [] }
        return file.models
            .map { name, spec in spec.config(name: name) }
            .sorted { $0.name < $1.name }
    }

    private struct ModelsFile: Decodable {
        let models: [String: ModelSpec]
    }

    private struct ModelSpec: Decodable {
        var provider: String?
        var baseURL: String?
        var url: String? // accepted as an alias for baseURL
        var model: String?
        var apiKey: String?
        var vision: Bool?
        var reasoning: Bool?
        var temperature: Double?
        var maxTokens: Int?
        var topP: Double?
        // Provider-specific (Anthropic / Azure / Bedrock); ignored by the OpenAI default.
        var anthropicVersion: String?
        var beta: [String]?
        var azureDeployment: String?
        var apiVersion: String?
        var region: String?
        var contextWindow: Int?

        func config(name: String) -> OpenAIModelConfig {
            OpenAIModelConfig(
                name: name,
                baseURL: resolveEnv(baseURL ?? url ?? ""),
                model: resolveEnv(model ?? name),
                apiKey: apiKey.map(resolveEnv),
                vision: vision ?? false,
                reasoning: reasoning ?? false,
                temperature: temperature,
                maxTokens: maxTokens,
                topP: topP,
                provider: RemoteProvider(provider),
                anthropicVersion: anthropicVersion.map(resolveEnv),
                betaHeaders: beta ?? [],
                azureDeployment: azureDeployment.map(resolveEnv),
                apiVersion: apiVersion.map(resolveEnv),
                region: region.map(resolveEnv),
                contextWindow: contextWindow
            )
        }
    }
}

/// Resolve a model-config value's environment references, so a secret stays out of the file.
/// Supports the bare shell form `$NAME` (the whole value names an environment variable) on top of
/// the `${NAME}` / `${NAME:-default}` forms ``expand`` handles. A reference to an unset variable
/// resolves to an empty string (matching `expand`); a literal that doesn't look like a reference is
/// returned unchanged.
func resolveEnv(_ value: String) -> String {
    // Bare `$NAME` (no braces): the entire value is an environment variable name. Inline `$NAME`
    // inside a larger string is deliberately not expanded (use `${NAME}` for that), so a literal
    // value that merely contains `$` is left untouched.
    if value.hasPrefix("$"), !value.hasPrefix("${") {
        let name = String(value.dropFirst())
        if isEnvName(name) { return ProcessInfo.processInfo.environment[name] ?? "" }
    }
    return expand(value)
}

/// True when `name` is a valid POSIX-style environment variable identifier (`[A-Za-z_][A-Za-z0-9_]*`).
private func isEnvName(_ name: String) -> Bool {
    guard let first = name.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
    return name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
}
