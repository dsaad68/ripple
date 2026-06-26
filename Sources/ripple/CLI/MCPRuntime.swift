import AppKit
import DeepAgents
import Foundation

/// The live MCP layer behind `ripple chat`: the configured servers, the tools currently loaded from
/// the ones we could connect to, and each server's status. Shared by the REPL (whose `build` closure
/// reads ``tools``/``approvalDefaults`` so a rebuild picks up the current set) and the ``ChatScreen``
/// `/mcp` browser (which can ``login(_:)`` an OAuth server and have its tools go live, no restart).
///
/// OAuth servers with no cached token are deliberately *not* connected at load - their browser
/// sign-in flow would block headlessly until it times out - so they surface as "not signed in" until
/// the user signs them in from `/mcp` (or `ripple mcp login`).
@MainActor
final class MCPRuntime {
    let servers: [MCPServerConfig]
    private(set) var tools: [any AgentTool] = []
    private(set) var approvalDefaults: [String: ToolApprovalMode] = [:]
    private(set) var statuses: [MCPServerStatus] = []
    /// The client backing the currently loaded ``tools``; kept alive so their sessions stay open,
    /// and reaped when a reload replaces it (or on ``shutdown()``).
    private var client: MultiServerMCPClient?

    init(servers: [MCPServerConfig]) { self.servers = servers }

    /// Whether `server` can be connected right now without opening a browser: a non-OAuth server, or
    /// an OAuth server with a cached Keychain token.
    func isSignedIn(_ server: MCPServerConfig) -> Bool {
        server.auth != .oauth || KeychainTokenStorage(serverID: server.id.uuidString).hasToken
    }

    /// Where an HTTP server stands on browser sign-in, used to drive the `/mcp` browser's hints and `r`
    /// key. ``notApplicable`` means there's nothing to sign into (stdio, static-header auth, or a plain
    /// server we reached fine).
    enum AuthState: Equatable { case notApplicable, needsAuth, signedIn }

    /// ``AuthState`` for `server`, reading its last connect status and cached token. A *plain* HTTP
    /// server (no `oauth` key) that answered 401 on its last connect is reported ``needsAuth`` - so it
    /// gets the same "press r to sign in" flow as a declared OAuth server, matching Claude Code, which
    /// discovers the requirement from the 401 rather than from config.
    func authState(_ server: MCPServerConfig) -> AuthState {
        Self.authState(
            server: server,
            statusError: statuses.first { $0.name == server.name }?.error,
            hasToken: KeychainTokenStorage(serverID: server.id.uuidString).hasToken
        )
    }

    /// The pure decision behind ``authState(_:)``, split out so it's testable without a live Keychain
    /// or a connected runtime. `nonisolated` so the CLI (`ripple mcp`) can reach it off the main actor.
    nonisolated static func authState(server: MCPServerConfig, statusError: String?, hasToken: Bool) -> AuthState {
        // OAuth applies only to HTTP; a user-set Authorization header is static header auth, not OAuth.
        guard server.kind == .http, !hasAuthorizationHeader(server) else { return .notApplicable }
        // A 401 on the last connect means sign-in is needed - even with a stale cached token (expired,
        // and refresh failed) - and is how a plain HTTP server's auth requirement is discovered at all.
        if isAuthRequiredError(statusError) { return .needsAuth }
        if hasToken { return .signedIn }
        if server.auth == .oauth { return .needsAuth } // declared OAuth, no cached token yet
        return .notApplicable
    }

    /// Whether `server` pins a static `Authorization` header (case-insensitive) - in which case we
    /// treat its auth as header-based and never offer the OAuth sign-in flow.
    nonisolated static func hasAuthorizationHeader(_ server: MCPServerConfig) -> Bool {
        server.headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
    }

    /// Whether a connect error string is the swift-sdk's "needs OAuth sign-in" 401. With no authorizer
    /// attached the SDK maps a 401 to `MCPError.internalError("Authentication required")` (a 403 is
    /// "Access forbidden", which a sign-in won't fix, so it's deliberately excluded). Matched on the
    /// message because the SDK's typed challenge error is internal; a unit test guards against drift.
    nonisolated static func isAuthRequiredError(_ error: String?) -> Bool {
        guard let error else { return false }
        return error.localizedCaseInsensitiveContains("Authentication required")
    }

    /// (Re)connect every server we can reach now and refresh ``tools``/``approvalDefaults``/
    /// ``statuses``. The previous client is reaped once the new tools are in place. OAuth servers
    /// with no token are reported as "not signed in" rather than connected.
    func reload() async {
        let connectable = servers.filter(isSignedIn)
        let needsLogin = servers.filter { !isSignedIn($0) }
        let previous = client
        let next = connectable.isEmpty ? nil : MultiServerMCPClient(configs: connectable)
        let loaded = await next?.load()
        tools = loaded?.tools ?? []
        approvalDefaults = mcpApprovalDefaults(servers: connectable, tools: tools)
        statuses = (loaded?.statuses ?? [])
            + needsLogin.map { MCPServerStatus(id: $0.id, name: $0.name, toolCount: 0, error: "not signed in") }
        client = next
        await previous?.disconnectAll()
    }

    /// Run the browser OAuth sign-in for `server` (a declared `oauth` server, or a plain HTTP server
    /// whose auth we discovered from a 401 - the authorizer is forced on either way), then ``reload()``
    /// so its tools go live. `force` (a re-auth) drops any cached token first so the browser flow
    /// always runs. Returns the server's status afterwards - connected with a tool count, or the
    /// error. The authorization URL opens through `NSWorkspace`, and the browser lands on ripple's
    /// own ``RippleOAuthPage`` (not the framework's Mispher page).
    func login(_ server: MCPServerConfig, force: Bool = false) async -> MCPServerStatus {
        let store = KeychainTokenStorage(serverID: server.id.uuidString)
        if force { store.clear() }
        let session = SwiftSDKMCPSession(config: server, openURL: { url in
            Task { @MainActor in _ = NSWorkspace.shared.open(url) }
        }, successHTML: RippleOAuthPage.signedIn, requireOAuth: true) // force the flow even with no `oauth` key
        do {
            try await session.connect() // 401 -> browser sign-in -> token cached in the Keychain
            _ = try await session.listTools()
            await session.disconnect()
        } catch {
            await session.disconnect()
        }
        if store.hasToken { await reload() }
        return statuses.first { $0.name == server.name }
            ?? MCPServerStatus(id: server.id, name: server.name, toolCount: 0, error: "sign-in did not complete")
    }

    /// Log `server` out: clear its cached Keychain token and reload, so its tools drop from the live
    /// set. Returns the server's status afterwards ("not signed in").
    @discardableResult
    func logout(_ server: MCPServerConfig) async -> MCPServerStatus {
        KeychainTokenStorage(serverID: server.id.uuidString).clear()
        await reload()
        return statuses.first { $0.name == server.name }
            ?? MCPServerStatus(id: server.id, name: server.name, toolCount: 0, error: "not signed in")
    }

    /// Close every open session and reap any launched subprocesses (on REPL exit).
    func shutdown() async {
        await client?.disconnectAll()
        client = nil
    }
}
