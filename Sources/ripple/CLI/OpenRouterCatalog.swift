import Foundation

/// A free model discovered from OpenRouter's public catalog (`GET /api/v1/models`), offered in the
/// `/models-config` browser's OpenRouter tab. Adding one writes an ``OpenAIModelConfig`` entry to
/// `~/.ripple/settings.json` that points at OpenRouter's OpenAI-compatible endpoint.
struct OpenRouterModel: Sendable, Hashable {
    /// The OpenRouter model id (e.g. `meta-llama/llama-3.3-70b-instruct:free`) - sent as `model` in
    /// each request and used as the `settings.json` entry name / `/model` selection id.
    let id: String
    /// The human-readable name (e.g. `Meta: Llama 3.3 70B Instruct (free)`).
    let name: String
    /// The advertised context window in tokens, when the catalog reports one.
    let contextLength: Int?
    /// True when the model accepts image input (its `architecture.input_modalities` lists `image`),
    /// so the added entry can also back the deep agent's `vision` subagent.
    let vision: Bool

    /// The provider slug - the id segment before the first `/` (e.g. `meta-llama`, `google`).
    var providerSlug: String { id.split(separator: "/").first.map(String.init) ?? id }

    /// The human provider name, used to group/label the OpenRouter tab: the `name` prefix before the
    /// first `: ` (e.g. `Meta`, `Google`, `NVIDIA`), falling back to the slug when the name has none.
    var providerLabel: String {
        if let range = name.range(of: ": ") { return String(name[..<range.lowerBound]) }
        return providerSlug
    }

    /// The model name without its `Provider: ` prefix and trailing ` (free)` - the readable label
    /// shown in the provider's model list (e.g. `Llama 3.3 70B Instruct`).
    var shortName: String {
        var short = name
        if let range = short.range(of: ": ") { short = String(short[range.upperBound...]) }
        if short.hasSuffix(" (free)") { short = String(short.dropLast(7)) }
        return short.isEmpty ? name : short
    }
}

/// Fetches OpenRouter's model catalog and keeps only the free ones. The list endpoint is public (no
/// API key); a key is only needed to *use* a model, so added entries reference `$OPENROUTER_API_KEY`
/// (see ``ChatScreen/toggleOpenRouterModel(at:)``).
enum OpenRouterCatalog {
    /// The free models from OpenRouter, sorted by name. "Free" is the `:free` id suffix OpenRouter
    /// uses for its no-cost variants - a priced model (even one that currently lists a zero prompt
    /// price, like a preview image/audio model) is excluded. The base URL honors the same
    /// `${OPENROUTER_BASE_URL:-…}` override the written entries use. Throws on a network, HTTP, or
    /// decoding failure.
    static func fetch() async throws -> [OpenRouterModel] {
        let base = resolveEnv("${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}")
        guard let url = URL(string: base)?.appending(path: "models") else {
            throw OpenRouterCatalogError.badURL(base)
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else { throw OpenRouterCatalogError.http(status: status) }
        return try models(from: data)
    }

    /// Decode an OpenRouter `/models` payload into the free models, sorted by name. Split from the
    /// network ``fetch()`` so the free/vision filtering is unit-testable against a captured payload.
    static func models(from data: Data) throws -> [OpenRouterModel] {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let free = decoded.data.filter { $0.isFree }
        let models = free.map { entry -> OpenRouterModel in
            OpenRouterModel(
                id: entry.id,
                name: entry.name ?? entry.id,
                contextLength: entry.contextLength,
                vision: entry.architecture?.inputModalities?.contains("image") ?? false
            )
        }
        return models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - OpenRouter `/models` schema (only the fields we use)

    private struct Response: Decodable {
        let data: [Entry]
    }

    private struct Entry: Decodable {
        let id: String
        let name: String?
        let contextLength: Int?
        let architecture: Architecture?

        /// Free models carry the `:free` id suffix on OpenRouter; anything else is a paid (or
        /// preview) variant and is hidden, even if it currently lists a zero token price.
        var isFree: Bool { id.hasSuffix(":free") }

        enum CodingKeys: String, CodingKey {
            case id, name, architecture
            case contextLength = "context_length"
        }
    }

    private struct Architecture: Decodable {
        let inputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
        }
    }
}

/// Why an OpenRouter catalog fetch failed, surfaced in the `/models-config` OpenRouter tab.
enum OpenRouterCatalogError: Error, CustomStringConvertible {
    case badURL(String)
    case http(status: Int)

    var description: String {
        switch self {
        case .badURL(let value): "Invalid OpenRouter base URL: \(value)"
        case .http(let status): "OpenRouter returned HTTP \(status)."
        }
    }
}
