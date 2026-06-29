import DeepAgents
import Foundation

/// Bridges the deep agent's human-in-the-loop approvals to the chat TUI. When a gated tool call runs
/// (`ls` / `read_file` / `write_file` / `edit_file` on the real filesystem), the agent's run suspends
/// inside ``present(_:)`` until the user's keypress resolves it via ``resolve(_:)``. The chat runs one
/// turn at a time, so a single pending slot suffices - the app's `MlxModelManager` keeps one per
/// concurrent run scope, but the REPL has no concurrency to disambiguate.
@MainActor
final class ApprovalGate {
    /// The tool call awaiting the user's decision, or nil when nothing is pending. Read by the screen.
    private(set) var pending: ToolApprovalRequest?
    private var continuation: CheckedContinuation<ToolApprovalDecision, Never>?
    /// Invoked after `pending` changes so the screen can redraw (the request arrives off the main
    /// loop, driven by the agent, so it needs to nudge a render itself).
    var onChange: (() -> Void)?

    /// Consulted before a call is shown to the user: return a decision to auto-resolve it (per the
    /// active permission mode or the allowlist), or nil to prompt. Lets "accept all" / "auto-reads" /
    /// "plan" run without a card ever appearing.
    var policy: ((ToolApprovalRequest) -> ToolApprovalDecision?)?

    /// The handler to hand to ``RippleDeepAgent``'s `make`; weakly captures the gate so the agent
    /// doesn't keep it alive.
    var handler: ToolApprovalHandler {
        { [weak self] request in await self?.present(request) ?? .reject(message: nil) }
    }

    private func present(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        if let decision = policy?(request) { return decision } // auto-resolved by the permission mode
        if let stale = continuation { // a superseded run - never silently drop a continuation
            continuation = nil
            stale.resume(returning: .reject(message: "The request was superseded."))
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            pending = request
            onChange?()
        }
    }

    /// Resolve the pending approval with the user's decision. A no-op when nothing is pending.
    func resolve(_ decision: ToolApprovalDecision) {
        guard let continuation else { return }
        self.continuation = nil
        pending = nil
        continuation.resume(returning: decision)
        onChange?()
    }
}
