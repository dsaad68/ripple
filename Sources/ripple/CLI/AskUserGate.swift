import DeepAgents
import Foundation

/// Bridges the deep agent's `ask_user` tool to the chat TUI. When the agent calls `ask_user`, its run
/// suspends inside ``present(_:)`` until the user submits answers (or cancels) and ``resolve(_:)``
/// feeds the result back. The chat runs one turn at a time, so a single pending slot suffices - the
/// approval counterpart is ``ApprovalGate``.
@MainActor
final class AskUserGate {
    /// The questions awaiting the user's answers, or nil when nothing is pending. Read by the screen.
    private(set) var pending: AskUserRequest?
    private var continuation: CheckedContinuation<AskUserResponse, Never>?
    /// Invoked after `pending` changes so the screen can redraw (the request arrives off the main loop,
    /// driven by the agent, so it needs to nudge a render itself).
    var onChange: (() -> Void)?

    /// The handler to hand to ``RippleDeepAgent``'s `make`; weakly captures the gate so the agent
    /// doesn't keep it alive.
    var handler: AskUserHandler {
        { [weak self] request in await self?.present(request) ?? .cancelled }
    }

    private func present(_ request: AskUserRequest) async -> AskUserResponse {
        if let stale = continuation { // a superseded run - never silently drop a continuation
            continuation = nil
            stale.resume(returning: .cancelled)
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            pending = request
            onChange?()
        }
    }

    /// Resolve the pending questions with the user's answers (or `.cancelled`). A no-op when nothing
    /// is pending.
    func resolve(_ response: AskUserResponse) {
        guard let continuation else { return }
        self.continuation = nil
        pending = nil
        continuation.resume(returning: response)
        onChange?()
    }
}
