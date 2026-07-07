import AppKit
import DeepAgents
import Foundation

/// `ripple mcp <list|add|remove|login>` - manage MCP servers from the command line instead of
/// hand-editing the three JSON files ripple merges. A thin front-end over the existing plumbing:
/// `add`/`remove` rewrite one server entry in the chosen scope's file (preserving every other entry
/// verbatim, see ``RippleAgentConfig/saveServerEntry(name:_:to:)``); `list` reports the configured
/// servers and, by default, probes each for reachability; `login` runs the same browser OAuth
/// loopback the app uses (``SwiftSDKMCPSession`` + ``KeychainTokenStorage``) so a server can be
/// signed in without launching the GUI.
///
/// Arg parsing is hand-rolled to match the rest of the CLI (`main.swift`'s `option(_:_:)`), and the
/// surface mirrors `claude mcp add`: a `--` separator introduces a stdio command, a positional URL
/// (or `--transport http`) selects http, and `--scope` picks which file to write.
@MainActor
enum RippleMCPCommand {
    static func run(_ args: [String]) async {
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let sub = args.first ?? "list"
        let rest = Array(args.dropFirst())
        switch sub {
        case "list", "ls": await list(rest, workingDirectory: workingDirectory)
        case "add": add(rest, workingDirectory: workingDirectory)
        case "remove", "rm": remove(rest, workingDirectory: workingDirectory)
        case "login": await login(rest, workingDirectory: workingDirectory)
        case "logout": logout(rest, workingDirectory: workingDirectory)
        case "-h", "--help", "help": usageMCP(nil)
        default: usageMCP("unknown mcp subcommand: \(sub)")
        }
    }

    // MARK: - list

    private static func list(_ args: [String], workingDirectory: URL) async {
        let probe = !args.contains("--no-probe")
        let resolved = RippleAgentConfig.resolvedServers(workingDirectory: workingDirectory)
        guard !resolved.isEmpty else {
            out(Paint.fg(244, "No MCP servers configured.") + "\n"
                + Paint.fg(240, "Add one with: ripple mcp add <name> --transport http <url>"))
            return
        }
        for (scope, config) in resolved {
            var bits = [config.kind == .http ? "http" : "stdio"]
            // Only label the auth scheme we can name from config: declared `oauth`, or a static
            // Authorization header. A plain HTTP server's auth is discovered at connect time (the probe
            // line below reports it), so it carries no auth label here.
            if config.auth == .oauth {
                bits.append("oauth")
            } else if config.kind == .http, MCPRuntime.hasAuthorizationHeader(config) {
                bits.append("headers")
            }
            bits.append("approval: \(config.approvalMode.rawValue)")
            bits.append(scope.label)
            out("  " + Paint.bold(config.name) + Paint.fg(240, "  ·  " + bits.joined(separator: "  ·  ")))
            let detail = config.kind == .http ? config.url : ([config.command] + config.args).joined(separator: " ")
            if !detail.isEmpty { out("    " + Paint.fg(244, detail)) }
            if probe { await out("    " + probeLine(config)) }
        }
    }

    /// A one-line reachability verdict for `list --probe`. OAuth servers without a cached token are
    /// reported "not signed in" without connecting (so a bulk `list` never pops a browser); everyone
    /// else gets a bounded connect + `listTools` and a tool count.
    private static func probeLine(_ config: MCPServerConfig) async -> String {
        if config.auth == .oauth, !KeychainTokenStorage(serverID: config.id.uuidString).hasToken {
            return Paint.fg(179, "○ not signed in")
                + Paint.fg(240, " - run: ripple mcp login \(config.name)")
        }
        do {
            let count = try await withTimeout(seconds: 15) {
                let session = SwiftSDKMCPSession(config: config) // no-op opener: never opens a browser here
                do {
                    try await session.connect()
                    let tools = try await session.listTools()
                    await session.disconnect()
                    return tools.count
                } catch {
                    await session.disconnect()
                    throw error
                }
            }
            return Paint.fg(114, "✓ reachable") + Paint.fg(240, " · \(count) tool\(count == 1 ? "" : "s")")
        } catch {
            // A plain HTTP server that answered 401 needs a browser sign-in (discovered, not declared) -
            // report it like a declared OAuth server rather than as a raw "unreachable" error.
            if MCPRuntime.isAuthRequiredError(error.localizedDescription), !MCPRuntime.hasAuthorizationHeader(config) {
                return Paint.fg(179, "○ not signed in")
                    + Paint.fg(240, " - run: ripple mcp login \(config.name)")
            }
            let reason = error is TimeoutError ? "timed out" : error.localizedDescription
            return Paint.fg(174, "✗ unreachable") + Paint.fg(240, " · \(reason)")
        }
    }

    // MARK: - add

    private static func add(_ args: [String], workingDirectory: URL) {
        let (head, commandTail) = splitAtDoubleDash(args)
        let positional = positionals(head)
        guard let name = positional.first, !name.isEmpty else {
            usageMCP("mcp add: a server name is required."); return
        }
        guard let scope = scopeValue(head),
              let kind = transportValue(head, commandTail: commandTail, positional: positional),
              let approval = approvalValue(head),
              let entry = buildEntry(
                  kind: kind, positional: positional, commandTail: commandTail, head: head, approval: approval
              )
        else { return }

        if RippleAgentConfig.scopesDefining(name: name, workingDirectory: workingDirectory).contains(scope),
           !head.contains("--force") {
            err("mcp add: '\(name)' already exists in \(scope.label). Use --force to overwrite."); return
        }
        do {
            try RippleAgentConfig.saveServerEntry(name: name, entry, to: scope.url(workingDirectory: workingDirectory))
            out(Paint.fg(114, "✓") + " added '\(name)' (\(kind == .http ? "http" : "stdio")) to \(scope.label)")
        } catch {
            err("mcp add: failed to write \(scope.label): \(error.localizedDescription)")
        }
    }

    /// The transport for `add`: an explicit `--transport` wins; otherwise it's inferred from a `--`
    /// command (stdio) or a positional URL (http). Nil after printing an error.
    private static func transportValue(
        _ args: [String], commandTail: [String], positional: [String]
    ) -> MCPServerConfig.Kind? {
        switch option(args, "--transport") {
        case "stdio": return .stdio
        case "http", "sse": return .http
        case .some(let other):
            err("mcp add: --transport must be stdio or http (got '\(other)').")
            return nil
        case nil where !commandTail.isEmpty: return .stdio
        case nil where positional.count > 1: return .http
        case nil:
            err("mcp add: give either `-- <command> ...` (stdio) or a <url> (http), or --transport.")
            return nil
        }
    }

    /// Build the raw Claude-schema entry for `add`, or nil after printing an error for a bad
    /// flag/transport combination (e.g. `--oauth` on a stdio server).
    private static func buildEntry(
        kind: MCPServerConfig.Kind, positional: [String], commandTail: [String],
        head: [String], approval: ToolApprovalMode
    ) -> [String: Any]? {
        var entry: [String: Any] = [:]
        switch kind {
        case .stdio:
            guard let command = commandTail.first else {
                err("mcp add: a stdio server needs a command after `--`, e.g. `-- npx -y some-server`.")
                return nil
            }
            if !options(head, "--header").isEmpty || head.contains("--oauth") {
                err("mcp add: --header / --oauth apply only to http servers.")
                return nil
            }
            entry["command"] = command
            let commandArgs = Array(commandTail.dropFirst())
            if !commandArgs.isEmpty { entry["args"] = commandArgs }
            let env = keyValues(options(head, "--env"), separator: "=", trimValue: false)
            if !env.isEmpty { entry["env"] = env }
        case .http:
            guard let url = positional.dropFirst().first else {
                err("mcp add: an http server needs a <url>.")
                return nil
            }
            if !options(head, "--env").isEmpty {
                err("mcp add: --env applies only to stdio servers (use --header for http).")
                return nil
            }
            entry["type"] = "http"
            entry["url"] = url
            let headers = keyValues(options(head, "--header"), separator: ":", trimValue: true)
            if !headers.isEmpty { entry["headers"] = headers }
            if head.contains("--oauth") { entry["oauth"] = [String: Any]() }
        }
        if approval != .ask { entry["approvalMode"] = approval.rawValue }
        return entry
    }

    // MARK: - remove

    private static func remove(_ args: [String], workingDirectory: URL) {
        guard let scope = scopeValue(args) else { return }
        guard let name = positionals(args).first, !name.isEmpty else {
            err("mcp remove: a server name is required."); return
        }
        do {
            if try RippleAgentConfig.removeServerEntry(name: name, from: scope.url(workingDirectory: workingDirectory)) {
                out(Paint.fg(114, "✓") + " removed '\(name)' from \(scope.label)")
            } else {
                let defined = RippleAgentConfig.scopesDefining(name: name, workingDirectory: workingDirectory)
                if defined.isEmpty {
                    err("mcp remove: no server named '\(name)' is configured.")
                } else {
                    err("mcp remove: '\(name)' isn't in \(scope.label); it's defined in "
                        + defined.map(\.label).joined(separator: ", ")
                        + ". Re-run with --scope \(defined[0].rawValue).")
                }
            }
        } catch {
            err("mcp remove: failed to write \(scope.label): \(error.localizedDescription)")
        }
    }

    // MARK: - login

    private static func login(_ args: [String], workingDirectory: URL) async {
        guard let name = positionals(args).first, !name.isEmpty else {
            err("mcp login: a server name is required."); return
        }
        guard let config = RippleAgentConfig.loadServers(workingDirectory: workingDirectory)
            .first(where: { $0.name == name })
        else {
            err("mcp login: no server named '\(name)' is configured."); return
        }
        // A declared OAuth server, or any plain HTTP server (Claude Code-style: its auth is discovered
        // from a 401, not from an `oauth` key). Reject stdio and static-header-auth servers - there's
        // nothing to sign into.
        guard config.kind == .http else {
            err("mcp login: '\(name)' is a stdio server; nothing to sign into."); return
        }
        guard !MCPRuntime.hasAuthorizationHeader(config) else {
            err("mcp login: '\(name)' uses a static Authorization header; nothing to sign into."); return
        }
        let store = KeychainTokenStorage(serverID: config.id.uuidString)
        if args.contains("--force") {
            store.clear()
        } else if store.hasToken {
            out(Paint.fg(114, "✓") + " '\(name)' is already signed in. Use --force to re-authenticate.")
            return
        }
        err(Paint.fg(244, "opening your browser to sign in to '\(name)'…"))
        let session = SwiftSDKMCPSession(config: config, openURL: { url in
            Task { @MainActor in _ = NSWorkspace.shared.open(url) }
        }, successHTML: RippleOAuthPage.signedIn, requireOAuth: true) // force the flow even with no `oauth` key
        do {
            try await session.connect()
            _ = try await session.listTools()
            await session.disconnect()
        } catch {
            await session.disconnect()
            // The browser flow may have stored a token even if the post-auth probe hiccuped; only
            // treat it as a failure if nothing landed in the Keychain.
            if !store.hasToken {
                err("mcp login: sign-in failed: \(error.localizedDescription)")
                return
            }
        }
        if store.hasToken {
            out(Paint.fg(114, "✓") + " signed in to '\(name)'. The token is saved in your Keychain.")
        } else {
            err("mcp login: sign-in did not complete (no token was stored).")
        }
    }

    // MARK: - logout

    private static func logout(_ args: [String], workingDirectory: URL) {
        guard let name = positionals(args).first, !name.isEmpty else {
            err("mcp logout: a server name is required."); return
        }
        guard let config = RippleAgentConfig.loadServers(workingDirectory: workingDirectory)
            .first(where: { $0.name == name })
        else {
            err("mcp logout: no server named '\(name)' is configured."); return
        }
        let store = KeychainTokenStorage(serverID: config.id.uuidString)
        if store.hasToken {
            store.clear()
            out(Paint.fg(114, "✓") + " logged out of '\(name)'; its cached token was removed.")
        } else {
            out(Paint.fg(244, "'\(name)' was not signed in."))
        }
    }

    // MARK: - Arg parsing

    /// Split `args` at the first standalone `--`; everything after it is a stdio command + its args.
    static func splitAtDoubleDash(_ args: [String]) -> (head: [String], tail: [String]) {
        guard let separator = args.firstIndex(of: "--") else { return (args, []) }
        return (Array(args[..<separator]), Array(args[(separator + 1)...]))
    }

    /// The non-flag tokens in `args`, skipping every `--flag` and the value of the value-taking ones.
    static func positionals(_ args: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let token = args[index]
            if valueFlags.contains(token) {
                index += 2
            } else if token.hasPrefix("-") {
                index += 1
            } else {
                result.append(token)
                index += 1
            }
        }
        return result
    }

    /// Every value passed for a repeatable flag (e.g. all `--env KEY=VAL`).
    static func options(_ args: [String], _ flag: String) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            if args[index] == flag, index + 1 < args.count {
                result.append(args[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    /// Parse `KEY<sep>VALUE` tokens into a dictionary. Headers (`--header "Key: Value"`) trim the
    /// value's surrounding whitespace; env (`--env KEY=VALUE`) keeps it verbatim.
    static func keyValues(_ tokens: [String], separator: Character, trimValue: Bool) -> [String: String] {
        var result: [String: String] = [:]
        for token in tokens {
            guard let split = token.firstIndex(of: separator) else { continue }
            let key = String(token[..<split]).trimmingCharacters(in: .whitespaces)
            var value = String(token[token.index(after: split)...])
            if trimValue { value = value.trimmingCharacters(in: .whitespaces) }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private static let valueFlags: Set<String> = ["--transport", "--scope", "--approval", "--env", "--header"]

    /// The `--scope` value (default `.project`), or nil after printing an error for a bad value.
    private static func scopeValue(_ args: [String]) -> RippleAgentConfig.Scope? {
        guard let raw = option(args, "--scope") else { return .project }
        guard let scope = RippleAgentConfig.Scope(rawValue: raw) else {
            err("mcp: --scope must be project, shared, or user (got '\(raw)')."); return nil
        }
        return scope
    }

    /// The `--approval` value (default `.ask`), or nil after printing an error for a bad value.
    private static func approvalValue(_ args: [String]) -> ToolApprovalMode? {
        guard let raw = option(args, "--approval") else { return .ask }
        guard let mode = ToolApprovalMode(rawValue: raw) else {
            err("mcp add: --approval must be approve, ask, or deny (got '\(raw)')."); return nil
        }
        return mode
    }

    // MARK: - Output + timeout

    private static func out(_ message: String) { print(message) }

    private static func err(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private struct TimeoutError: Error {}

    /// Run `operation`, throwing ``TimeoutError`` if it doesn't finish within `seconds` - so a
    /// hung/unreachable server doesn't stall `mcp list`.
    private static func withTimeout<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TimeoutError() }
            return result
        }
    }

    private static func usageMCP(_ message: String?) {
        if let message { err("error: \(message)") }
        err("""
        usage:
          ripple mcp list [--no-probe]                    list servers (probes each unless --no-probe)
          ripple mcp add <name> [options] -- <cmd> [args] add a stdio server
          ripple mcp add <name> <url> --transport http    add an http server
            [--scope project|shared|user]   where to write (default project = .ripple/mcp.json)
            [--env KEY=VALUE ...]           stdio environment variables
            [--header "Key: Value" ...]     http request headers
            [--oauth]                       http: sign in via browser OAuth
            [--approval approve|ask|deny]   how the agent gates this server's tools (default ask)
            [--force]                       overwrite an existing server of the same name
          ripple mcp remove <name> [--scope project|shared|user]   delete a server
          ripple mcp login <name> [--force]                        browser OAuth sign-in for a server
          ripple mcp logout <name>                                 clear a server's cached OAuth token
        """)
    }
}
