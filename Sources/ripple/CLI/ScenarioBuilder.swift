import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation

/// Builds a `ReactAgent` from a decoded ``DeepAgentScenario`` using the generic `createDeepAgent`
/// factory and the ``ScenarioRegistry``. The topology - planner model, subagents, and which
/// middleware/tools attach to which agent - comes entirely from the spec, so a scenario can be
/// re-shaped by editing TOML with no recompile.
@MainActor
enum ScenarioBuilder {
    /// The per-run wiring a scenario is built against - everything that varies by run rather than
    /// by the scenario spec itself.
    struct Context {
        /// The capture source the `screenshot` middleware reads from (fixtures here).
        let screenCapture: any ScreenCaptureProviding
        /// Scratch directory used as the real-disk root when `backend = "local"`, so filesystem
        /// tools stay inside the run dir rather than touching the user's home.
        let localRoot: URL
        /// The JSONL trace sink for this scenario.
        let messageLog: (any AgentMessageLog)?
        /// Short-term memory for multi-turn scenarios.
        let memory: (any AgentCheckpointer)?
    }

    static func build(
        _ scenario: DeepAgentScenario,
        manager: MlxModelLoader,
        context: Context
    ) async throws -> ReactAgent {
        let spec = scenario.agent
        let screenCapture = context.screenCapture

        guard let plannerModel = await manager.loadChatModel(spec.model) else {
            throw ScenarioError.unknownModel(spec.model)
        }

        let plannerMiddleware = try spec.middleware.map {
            try ScenarioRegistry.middleware(named: $0, screenCapture: screenCapture)
        }
        let plannerTools = try spec.tools.map { try ScenarioRegistry.tool(named: $0) }

        var subagents: [SubAgent] = []
        for sub in spec.subagents {
            var subModel: (any ChatModel)?
            if let modelID = sub.model {
                guard let loaded = await manager.loadChatModel(modelID) else {
                    throw ScenarioError.unknownModel(modelID)
                }
                subModel = loaded
            }
            let subMiddleware = try sub.middleware.map {
                try ScenarioRegistry.middleware(named: $0, screenCapture: screenCapture)
            }
            // `nil` tools inherit the planner's; an explicit (possibly empty) list is resolved.
            let subTools = try sub.tools.map { names in
                try names.map { try ScenarioRegistry.tool(named: $0) }
            }
            subagents.append(
                SubAgent(
                    name: sub.name,
                    description: sub.description,
                    systemPrompt: ScenarioRegistry.prompt(sub.systemPrompt)
                        ?? "Complete the delegated task and return a concise result.",
                    tools: subTools,
                    model: subModel,
                    middleware: subMiddleware,
                    maxIterations: sub.maxIterations
                )
            )
        }

        let useLocalDisk = spec.backend == "local"
        let backend: (any FilesystemBackend)? =
            useLocalDisk ? LocalFilesystemBackend(rootURL: context.localRoot) : nil
        let approvalHandler: ToolApprovalHandler? =
            useLocalDisk ? Self.approvalHandler(spec.approvals) : nil
        let interruptOn: [String: InterruptOnConfig] =
            useLocalDisk ? RippleDeepAgent.fileApprovals : [:]

        return createDeepAgent(
            model: plannerModel,
            tools: plannerTools,
            systemPrompt: ScenarioRegistry.prompt(spec.systemPrompt),
            subagents: subagents,
            middleware: plannerMiddleware,
            memory: context.memory,
            backend: backend,
            interruptOn: interruptOn,
            approvalHandler: approvalHandler,
            includeFilesystem: spec.includeFilesystem,
            includeGeneralPurpose: spec.includeGeneralPurpose,
            maxIterations: spec.maxIterations,
            messageLog: context.messageLog
        )
    }

    /// The headless stand-in for the UI approval card: approve (or reject) every gated tool call,
    /// so a real-disk run never suspends waiting on a human that isn't there.
    private static func approvalHandler(_ policy: String) -> ToolApprovalHandler {
        if policy == "auto-reject" {
            return { _ in .reject(message: "Auto-rejected by the headless scenario harness.") }
        }
        return { _ in .approve }
    }
}
