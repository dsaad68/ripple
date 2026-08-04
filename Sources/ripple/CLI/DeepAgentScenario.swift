import DeepAgents
import DeepAgentsMLX
import Foundation

/// One headless test: the full agent topology to build (planner + subagents + which
/// middleware/tools attach to which agent), the prompts to run, optional screenshot/clipboard
/// fixtures, and optional expected signatures. Authored as TOML; the wrapper script normalizes
/// each `.toml` into the JSON this type decodes (and resolves fixture paths to absolute).
///
/// Snake_case keys are mapped explicitly (rather than a global decoding strategy) so the
/// free-form ``expect`` block passes through verbatim — its keys are the analyzer's signature
/// names and must not be camel-cased.
struct DeepAgentScenario: Decodable, Sendable {
    let id: String
    let agent: AgentSpec
    let prompts: Prompts
    let fixtures: Fixtures?
    /// Optional expectations, copied verbatim into the run manifest for the Python analyzer to
    /// diff against the observed signatures. Values are scalars (bool/int/double/string).
    let expect: [String: ScalarValue]?

    enum CodingKeys: String, CodingKey {
        case id, agent, prompts, fixtures, expect
    }

    /// The planner agent.
    struct AgentSpec: Decodable, Sendable {
        /// Hugging Face id of the planner model (a `MlxModel.catalog` id).
        let model: String
        /// Registry key (e.g. `DeepScreenPrompt`) or inline prompt text. Composed after the
        /// base deep-agent prompt.
        let systemPrompt: String?
        /// Extra middleware to attach (registry keys, e.g. `screenshot`, `clipboard`, `utility`).
        let middleware: [String]
        /// Extra standalone tools to attach (registry keys, e.g. `calculator`).
        let tools: [String]
        let includeFilesystem: Bool
        let includeGeneralPurpose: Bool
        let maxIterations: Int
        /// `"memory"` (in-memory scratch filesystem) or `"local"` (real disk, gated by approvals).
        let backend: String
        /// `"auto-approve"` or `"auto-reject"` — the headless stand-in for the UI approval card.
        let approvals: String
        let subagents: [SubAgentSpec]

        enum CodingKeys: String, CodingKey {
            case model, middleware, tools, backend, approvals, subagents
            case systemPrompt = "system_prompt"
            case includeFilesystem = "include_filesystem"
            case includeGeneralPurpose = "include_general_purpose"
            case maxIterations = "max_iterations"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try c.decode(String.self, forKey: .model)
            systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
            middleware = try c.decodeIfPresent([String].self, forKey: .middleware) ?? []
            tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
            includeFilesystem = try c.decodeIfPresent(Bool.self, forKey: .includeFilesystem) ?? false
            includeGeneralPurpose =
                try c.decodeIfPresent(Bool.self, forKey: .includeGeneralPurpose) ?? false
            maxIterations = try c.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 24
            backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? "memory"
            approvals = try c.decodeIfPresent(String.self, forKey: .approvals) ?? "auto-approve"
            subagents = try c.decodeIfPresent([SubAgentSpec].self, forKey: .subagents) ?? []
        }
    }

    /// A subagent the `task` tool can delegate to.
    struct SubAgentSpec: Decodable, Sendable {
        let name: String
        let description: String
        /// Model override; `nil` inherits the planner's model.
        let model: String?
        /// Registry key or inline prompt text. Required by `SubAgent`, defaulted to empty here so
        /// a bare subagent still decodes (the builder substitutes a minimal prompt).
        let systemPrompt: String?
        /// Tool registry keys. Omit the key to inherit the planner's tools; `[]` gives none.
        let tools: [String]?
        /// Extra middleware registry keys to run the subagent with.
        let middleware: [String]
        let maxIterations: Int

        enum CodingKeys: String, CodingKey {
            case name, description, model, tools, middleware
            case systemPrompt = "system_prompt"
            case maxIterations = "max_iterations"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
            model = try c.decodeIfPresent(String.self, forKey: .model)
            systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
            tools = try c.decodeIfPresent([String].self, forKey: .tools)
            middleware = try c.decodeIfPresent([String].self, forKey: .middleware) ?? []
            maxIterations = try c.decodeIfPresent(Int.self, forKey: .maxIterations) ?? 24
        }
    }

    struct Prompts: Decodable, Sendable {
        /// One entry per conversation turn; multi-turn scenarios replay earlier turns from memory.
        let turns: [String]
    }

    struct Fixtures: Decodable, Sendable {
        /// Seed text written to the system clipboard before the run (for clipboard scenarios).
        let clipboard: String?
        /// Per-window fixtures, front-to-back, surfaced by `take_window_screenshots`.
        let windows: [FixtureWindow]
        /// Optional dedicated full-screen fixture for `take_screenshot`.
        let screen: String?

        struct FixtureWindow: Decodable, Sendable {
            /// Human-facing window name ("App — Title") the planner sees in the manifest.
            let name: String
            /// Absolute path to the PNG (the wrapper resolves relative TOML paths).
            let png: String
        }

        enum CodingKeys: String, CodingKey { case clipboard, windows, screen }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clipboard = try c.decodeIfPresent(String.self, forKey: .clipboard)
            windows = try c.decodeIfPresent([FixtureWindow].self, forKey: .windows) ?? []
            screen = try c.decodeIfPresent(String.self, forKey: .screen)
        }
    }
}

/// A scalar TOML/JSON value (bool, integer, double, or string) — what an `expect` entry holds.
/// `Codable` so the runner can re-emit the block verbatim into the manifest.
enum ScalarValue: Sendable, Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: Foundation's JSONDecoder won't coerce a number into Bool, so trying
        // Bool first is safe and keeps `true`/`false` from being read as ints.
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        self = try .string(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}
