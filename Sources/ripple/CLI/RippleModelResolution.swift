import DeepAgents
import DeepAgentsMLX
import Foundation

/// The single source of truth for turning a model selection into the live ``ChatModel``s the deep
/// agent runs on. Every entry point - `ripple chat` (``DeepAgentREPL``), `ripple -p`
/// (``HeadlessRun``), and a live `/model` rebuild - resolves through here, so the planner + vision
/// + idle behaviour can't drift between them.
///
/// A selection is a ``DeepAgentVariant`` (an on-device preset, a synthesized custom planner, or a
/// remote OpenAI-compatible model). The planner comes from the variant's `textModelID`; the vision
/// model is the project's configured `visionModel` (set in `/model`'s Select tab) falling back to the
/// variant's default (an empty id turns vision off). A local model loads lazily and idle-unloads via
/// ``MlxModelLoader``; a remote model is built directly from its ``OpenAIModelConfig`` (nothing is
/// held in memory, so there's no lazy/idle layer).
@MainActor
enum RippleModelResolution {
    /// Whether `id` names a model ripple can actually start: a registered remote model, a known
    /// on-device variant, or a downloadable MLX catalog entry. Used to ignore a stale persisted
    /// project model (a removed/renamed model) rather than booting into a planner that can't load.
    static func isKnownModel(_ id: String, remote: [OpenAIModelConfig]) -> Bool {
        remote.contains { $0.name == id }
            || DeepAgentVariant.all.contains { $0.textModelID == id }
            || MlxModel.catalog.contains { $0.id == id }
    }

    /// The variant to start in: a known variant whose planner matches `--model`, else a synthesized
    /// variant for a custom planner id, else the default 8B-A1B deep agent.
    static func resolveVariant(_ override: String?, remote: [OpenAIModelConfig]) -> DeepAgentVariant {
        let fallback = DeepAgentVariant.all.first { $0.id == "mispher.deepagent" } ?? DeepAgentVariant.all[0]
        guard let override else { return fallback }
        // A configured OpenAI-compatible model wins by name (no download, possibly no vision).
        if let config = remote.first(where: { $0.name == override }) { return DeepAgentVariant.remote(config) }
        if let match = DeepAgentVariant.all.first(where: { $0.textModelID == override }) { return match }
        return DeepAgentVariant(
            id: "custom",
            label: MlxModel.catalog.first { $0.id == override }?.shortName ?? "custom",
            detail: "custom planner",
            textModelID: override,
            visionModelID: fallback.visionModelID
        )
    }

    /// The vision model id for `variant`: the project's configured `visionModel` (`/model`'s Select
    /// tab) overrides the variant default; an empty string means the user turned vision off. The one
    /// place the "configured-vision-else-variant-default" rule lives.
    static func configuredVisionID(_ variant: DeepAgentVariant, workingDirectory: URL) -> String {
        RippleAgentConfig.loadVisionModel(workingDirectory: workingDirectory) ?? variant.visionModelID
    }

    /// The model ids that must be on disk for `variant`: the planner plus the configured vision model.
    /// Empty for a remote variant. A vision id is only listed for download when it's a **local**
    /// catalog model - a remote vision model has nothing on disk to fetch.
    static func requiredModelIDs(_ variant: DeepAgentVariant, workingDirectory: URL) -> [String] {
        guard !variant.isRemote else { return [] }
        let vision = configuredVisionID(variant, workingDirectory: workingDirectory)
        let needsVision = !vision.isEmpty && MlxModel.catalog.contains { $0.id == vision }
        return [variant.textModelID] + (needsVision ? [vision] : [])
    }

    /// Resolve `id` to a ``ChatModel`` that loads lazily and idle-unloads. A remote (OpenAI-compatible)
    /// model is built directly - nothing is loaded into memory, so there's no lazy/idle. A local MLX
    /// model is wrapped in a ``LazyChatModel`` bound to the loader's idle layer: it loads on its first
    /// turn (the planner is pre-warmed at launch; the VL model loads only when a visual question is
    /// delegated) and is freed after `idleMinutes` of no use (`0` keeps it resident). Returns nil if a
    /// local id isn't in the catalog.
    static func lazyChatModel(
        _ id: String, manager: MlxModelLoader, remote: [OpenAIModelConfig], idleMinutes: Int
    ) -> (any ChatModel)? {
        if let config = remote.first(where: { $0.name == id }) { return config.chatModel() }
        guard let model = MlxModel.catalog.first(where: { $0.id == id }) else { return nil }
        return LazyChatModel(
            supportsVision: model.isVision, modelID: model.id,
            contextWindowTokens: model.contextWindowTokens,
            begin: {
                guard let chat = await manager.beginUse(id) else { throw RippleModelError.unavailable(id) }
                return chat
            },
            end: { await manager.endUse(id, idleMinutes: idleMinutes) }
        )
    }

    /// Resolve `choice`'s planner + vision as lazy, idle-unloading models (idle timeouts from `/model`).
    /// The configured vision model (else the variant default) overrides `choice.visionModelID`; an empty
    /// vision id drops the vision subagent. Returns nil only if the **planner** can't be resolved - a
    /// configured vision model that no longer resolves (e.g. a remote model removed after it was picked)
    /// degrades to vision-off rather than bricking the whole agent, mirroring how a stale `selectedModel`
    /// is ignored (see ``isKnownModel``).
    static func deepAgentModels(
        choice: DeepAgentVariant, manager: MlxModelLoader, workingDirectory: URL, remote: [OpenAIModelConfig]
    ) -> (planner: any ChatModel, vision: (any ChatModel)?)? {
        guard let planner = lazyChatModel(
            choice.textModelID, manager: manager, remote: remote,
            idleMinutes: RippleAgentConfig.loadPlannerIdleMinutes(workingDirectory: workingDirectory)
        ) else { return nil }
        let visionID = configuredVisionID(choice, workingDirectory: workingDirectory)
        guard !visionID.isEmpty else { return (planner, nil) }
        // A stale / removed vision id (no longer a catalog model or a registered remote) drops vision
        // instead of failing the build - the planner still runs.
        let vision = lazyChatModel(
            visionID, manager: manager, remote: remote,
            idleMinutes: RippleAgentConfig.loadVisionIdleMinutes(workingDirectory: workingDirectory)
        )
        return (planner, vision)
    }
}

/// A configured deep-agent model id that isn't in the catalog or fails to load.
enum RippleModelError: Error { case unavailable(String) }
