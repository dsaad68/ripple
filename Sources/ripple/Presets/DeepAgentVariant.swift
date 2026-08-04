import DeepAgents
import Foundation

/// A selectable DeepAgent configuration offered in the Ask picker: a planner (text) model plus the
/// vision-subagent model. Its `id` is a sentinel Ask selection — NOT a Hugging Face catalog id — and
/// `MlxModelManager` expands it into the two real models so both stay resident while it's selected.
/// Both variants share `RippleDeepAgent.make`; only the planner model differs.
struct DeepAgentVariant: Identifiable, Sendable, Hashable {
    /// Sentinel Ask-selection id (persisted as `askModelId`); never a catalog model id.
    let id: String
    /// Short label for the pill / status (e.g. "DeepAgent").
    let label: String
    /// Picker subtitle describing the models (e.g. "8B-A1B + vision").
    let detail: String
    /// The planner (text) model that breaks tasks into todos and delegates.
    let textModelID: String
    /// The `vision` subagent model (VLM) — the only one that can see a forwarded screenshot. Empty
    /// for a text-only remote variant (no vision subagent).
    let visionModelID: String
    /// True when this variant's models are remote (OpenAI-compatible). The MLX download/cache paths
    /// skip a remote variant — nothing lives on disk to fetch — and its models are built directly
    /// from an ``OpenAIModelConfig`` rather than loaded by ``MlxModelLoader``.
    var isRemote = false

    /// The catalog model ids this variant needs resident — empty for a remote variant.
    var modelIDs: [String] { isRemote ? [] : [textModelID, visionModelID] }

    /// All DeepAgent variants offered in the Ask picker, in display order.
    static let all: [DeepAgentVariant] = [
        DeepAgentVariant(
            id: "mispher.deepagent",
            label: "DeepAgent",
            detail: "8B-A1B + vision",
            textModelID: "LiquidAI/LFM2.5-8B-A1B-MLX-8bit",
            visionModelID: "mlx-community/LFM2.5-VL-1.6B-8bit"
        ),
        DeepAgentVariant(
            id: "mispher.deepagent.instruct",
            label: "DeepAgent (Instruct)",
            detail: "1.2B Instruct bf16 + vision",
            textModelID: "LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16",
            visionModelID: "mlx-community/LFM2.5-VL-1.6B-8bit"
        ),
        DeepAgentVariant(
            id: "mispher.deepagent.thinking",
            label: "DeepAgent (Thinking)",
            detail: "1.2B Thinking bf16 + vision",
            textModelID: "LiquidAI/LFM2.5-1.2B-Thinking-MLX-bf16",
            visionModelID: "mlx-community/LFM2.5-VL-1.6B-8bit"
        ),
        // Ornith is a single qwen3_5 VLM that both plans (with <think> + tools) and sees images, so
        // it backs the planner and the vision subagent at once.
        DeepAgentVariant(
            id: "mispher.deepagent.ornith",
            label: "DeepAgent (Ornith)",
            detail: "Ornith 9B reasoning + vision",
            textModelID: "mlx-community/Ornith-1.0-9B-4bit",
            visionModelID: "mlx-community/Ornith-1.0-9B-4bit"
        ),
        // Gemma 4 E4B plans with a thought channel + native tool calls; the LFM2.5 VLM backs the
        // vision subagent for now (Gemma 4's own vision path is blocked on an upstream MLXVLM
        // loader bug - see the catalog note; make it dual-role like Ornith once fixed).
        DeepAgentVariant(
            id: "mispher.deepagent.gemma4",
            label: "DeepAgent (Gemma 4)",
            detail: "Gemma 4 E4B reasoning + vision",
            textModelID: "mlx-community/gemma-4-e4b-it-8bit",
            visionModelID: "mlx-community/LFM2.5-VL-1.6B-8bit"
        )
    ]

    /// The variant for a sentinel selection id, or nil if `id` is an ordinary model selection.
    static func variant(for id: String) -> DeepAgentVariant? {
        all.first { $0.id == id }
    }

    /// A remote variant for an ``OpenAIModelConfig``: the planner runs the configured endpoint, and
    /// when `vision` is set the same remote model also backs the `vision` subagent (else text-only).
    static func remote(_ config: OpenAIModelConfig) -> DeepAgentVariant {
        DeepAgentVariant(
            id: "remote:\(config.name)",
            label: config.name,
            detail: config.vision ? "\(config.model) + vision" : "\(config.model) · remote",
            textModelID: config.name,
            visionModelID: config.vision ? config.name : "",
            isRemote: true
        )
    }
}
