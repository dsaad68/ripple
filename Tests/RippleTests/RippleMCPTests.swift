@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
@testable import ripple
import Testing

// Tests for ripple's MCP wiring: loading `.ripple/mcp.json` / `tool-policy.json`, and the `/mcp`
// browser that groups loaded tools by server with their approval mode.

@Suite("RippleAgentConfig")
struct RippleAgentConfigTests {
    /// Write files (by relative path) into a fresh temp project directory and return its URL.
    private func makeProject(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ripple-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relative, contents) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("Reads Claude Code mcpServers from .mcp.json and .ripple/mcp.json, merged")
    func loadsClaudeSchema() throws {
        let project = try makeProject([
            ".mcp.json": """
            { "mcpServers": {
                "parallel": { "type": "http", "url": "https://search.parallel.ai/mcp", "approvalMode": "approve" },
                "local":    { "command": "/bin/echo", "args": ["hi"], "env": { "K": "V" } }
            } }
            """,
            ".ripple/mcp.json": """
            { "mcpServers": { "wiki": { "type": "http", "url": "https://mcp.deepwiki.com/mcp", "oauth": {} } } }
            """
        ])
        let servers = RippleAgentConfig.loadServers(sources: [
            project.appendingPathComponent(".mcp.json"),
            project.appendingPathComponent(".ripple/mcp.json")
        ])
        let byName = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["parallel", "local", "wiki"])
        #expect(byName["parallel"]?.kind == .http)
        #expect(byName["parallel"]?.approvalMode == .approve)
        #expect(byName["local"]?.kind == .stdio)
        #expect(byName["local"]?.command == "/bin/echo")
        #expect(byName["local"]?.args == ["hi"])
        #expect(byName["local"]?.env == ["K": "V"])
        #expect(byName["wiki"]?.auth == .oauth)
    }

    @Test("Same server name: the first source wins")
    func firstSourceWins() throws {
        let project = try makeProject([
            ".mcp.json": #"{ "mcpServers": { "dup": { "type": "http", "url": "https://a/mcp" } } }"#,
            ".ripple/mcp.json": #"{ "mcpServers": { "dup": { "type": "http", "url": "https://b/mcp" } } }"#
        ])
        let servers = RippleAgentConfig.loadServers(sources: [
            project.appendingPathComponent(".mcp.json"),
            project.appendingPathComponent(".ripple/mcp.json")
        ])
        #expect(servers.count == 1)
        #expect(servers.first?.url == "https://a/mcp")
    }

    @Test("Expands ${VAR} and ${VAR:-default} from the environment")
    func expandsEnv() {
        withEnvironment(["RIPPLE_TEST_KEY": "secret123"]) {
            #expect(expand("Bearer ${RIPPLE_TEST_KEY}") == "Bearer secret123")
            #expect(expand("${RIPPLE_MISSING_VAR:-https://fallback.example}/mcp") == "https://fallback.example/mcp")
            #expect(expand("no vars here") == "no vars here")
        }
    }

    @Test("Policy loads from .ripple/tool-policy.json")
    func loadsPolicy() throws {
        let project = try makeProject([".ripple/tool-policy.json": #"{"disabledMiddleware":["clipboard"]}"#])
        #expect(RippleAgentConfig.loadPolicy(workingDirectory: project).disabledMiddleware == ["clipboard"])
    }

    @Test("Transport inference: sse and url-without-type are HTTP; a bare command is stdio")
    func transportInference() {
        let servers = RippleAgentConfig.parseClaudeMCP(Data("""
        { "mcpServers": {
            "sse-srv": { "type": "sse", "url": "https://s/mcp" },
            "url-srv": { "url": "https://u/mcp" },
            "cmd-srv": { "command": "/bin/echo" }
        } }
        """.utf8))
        let byName = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })
        #expect(byName["sse-srv"]?.kind == .http)
        #expect(byName["url-srv"]?.kind == .http)
        #expect(byName["cmd-srv"]?.kind == .stdio)
    }

    @Test("Server id is derived stably from the name (so OAuth tokens survive reloads)")
    func stableID() {
        let json = Data(#"{ "mcpServers": { "x": { "type": "http", "url": "https://x/mcp" } } }"#.utf8)
        #expect(RippleAgentConfig.parseClaudeMCP(json).first?.id == RippleAgentConfig.parseClaudeMCP(json).first?.id)
        let other = Data(#"{ "mcpServers": { "y": { "type": "http", "url": "https://y/mcp" } } }"#.utf8)
        #expect(RippleAgentConfig.parseClaudeMCP(json).first?.id != RippleAgentConfig.parseClaudeMCP(other).first?.id)
    }

    // MARK: - Writing (mcp add / mcp remove)

    @Test("add writes a Claude entry that loadServers reads back (stdio + http)")
    func addRoundTrips() throws {
        let project = try makeProject([:])
        let url = RippleAgentConfig.Scope.project.url(workingDirectory: project)
        try RippleAgentConfig.saveServerEntry(
            name: "fs", ["command": "/bin/echo", "args": ["hi"], "env": ["K": "V"]], to: url
        )
        try RippleAgentConfig.saveServerEntry(
            name: "api", ["type": "http", "url": "https://api.example.com/mcp", "approvalMode": "approve"], to: url
        )
        let byName = Dictionary(
            uniqueKeysWithValues: RippleAgentConfig.loadServers(workingDirectory: project).map { ($0.name, $0) }
        )
        #expect(byName["fs"]?.kind == .stdio)
        #expect(byName["fs"]?.command == "/bin/echo")
        #expect(byName["fs"]?.args == ["hi"])
        #expect(byName["fs"]?.env == ["K": "V"])
        #expect(byName["api"]?.kind == .http)
        #expect(byName["api"]?.url == "https://api.example.com/mcp")
        #expect(byName["api"]?.approvalMode == .approve)
    }

    @Test("Writing one server preserves an untouched sibling's ${VAR} placeholder verbatim")
    func writePreservesSiblingPlaceholders() throws {
        let project = try makeProject([
            ".ripple/mcp.json": #"""
            { "mcpServers": { "api": { "type": "http", "url": "${API_BASE}/mcp",
              "headers": { "Authorization": "Bearer ${API_KEY}" } } } }
            """#
        ])
        let url = RippleAgentConfig.Scope.project.url(workingDirectory: project)
        try RippleAgentConfig.saveServerEntry(name: "fs", ["command": "/bin/echo"], to: url)
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("${API_BASE}/mcp")) // not expanded to a literal when the file is rewritten
        #expect(raw.contains("Bearer ${API_KEY}"))
        #expect(raw.contains("\"fs\"")) // and the newly added server is present
    }

    @Test("remove deletes only the named server and reports an absent one")
    func removeDeletesOneServer() throws {
        let project = try makeProject([
            ".ripple/mcp.json": #"""
            { "mcpServers": { "a": { "type": "http", "url": "https://a/mcp" },
              "b": { "type": "http", "url": "https://b/mcp" } } }
            """#
        ])
        let url = RippleAgentConfig.Scope.project.url(workingDirectory: project)
        #expect(try RippleAgentConfig.removeServerEntry(name: "a", from: url) == true)
        #expect(try RippleAgentConfig.removeServerEntry(name: "missing", from: url) == false)
        #expect(Set(RippleAgentConfig.loadServers(workingDirectory: project).map(\.name)) == ["b"])
    }

    @Test("Scope routes to the right file; resolvedServers tags each server with its source (first wins)")
    func scopeRoutingAndOrigin() throws {
        let project = try makeProject([
            ".mcp.json": #"""
            { "mcpServers": { "shared": { "type": "http", "url": "https://s/mcp" },
              "dup": { "type": "http", "url": "https://a/mcp" } } }
            """#,
            ".ripple/mcp.json": #"""
            { "mcpServers": { "proj": { "type": "http", "url": "https://p/mcp" },
              "dup": { "type": "http", "url": "https://b/mcp" } } }
            """#
        ])
        #expect(RippleAgentConfig.Scope.shared.url(workingDirectory: project).lastPathComponent == ".mcp.json")
        #expect(
            Array(RippleAgentConfig.Scope.project.url(workingDirectory: project).pathComponents.suffix(2))
                == [".ripple", "mcp.json"]
        )

        let byName = Dictionary(
            uniqueKeysWithValues: RippleAgentConfig.resolvedServers(workingDirectory: project)
                .map { ($0.config.name, $0.scope) }
        )
        #expect(byName["shared"] == .shared)
        #expect(byName["proj"] == .project)
        #expect(byName["dup"] == .shared) // .mcp.json is earlier in merge order, so it wins
    }
}

@MainActor
@Suite("mcp arg parsing")
struct RippleMCPArgParsingTests {
    @Test("`--` splits the stdio command from the flags")
    func doubleDashSplit() {
        let (head, tail) = RippleMCPCommand.splitAtDoubleDash(["fs", "--scope", "user", "--", "npx", "-y", "srv"])
        #expect(head == ["fs", "--scope", "user"])
        #expect(tail == ["npx", "-y", "srv"])
    }

    @Test("positionals skip flags and the values of value-taking flags")
    func positionals() {
        #expect(
            RippleMCPCommand.positionals(["foo", "--transport", "http", "https://x/mcp", "--oauth"])
                == ["foo", "https://x/mcp"]
        )
    }

    @Test("options collects every occurrence of a repeated flag")
    func repeatedOptions() {
        #expect(
            RippleMCPCommand.options(["--env", "A=1", "--env", "B=2", "--scope", "user"], "--env") == ["A=1", "B=2"]
        )
    }

    @Test("keyValues parses env verbatim and trims header values")
    func keyValues() {
        #expect(RippleMCPCommand.keyValues(["A=1", "B=2"], separator: "=", trimValue: false) == ["A": "1", "B": "2"])
        #expect(
            RippleMCPCommand.keyValues(["Authorization: Bearer xyz"], separator: ":", trimValue: true)
                == ["Authorization": "Bearer xyz"]
        )
    }
}

@MainActor
@Suite("/mcp browser")
struct MCPBrowserTests {
    @Test("Groups loaded tools by server with transport, auth, and approval")
    func groupsByServer() {
        let servers = [
            MCPServerConfig(name: "parallel-search", kind: .http, url: "https://x/mcp", approvalMode: .ask),
            MCPServerConfig(
                name: "deepwiki", kind: .http, url: "https://y/mcp", auth: .oauth, approvalMode: .approve
            )
        ]
        let mcpTools: [any AgentTool] = [
            NamedTool("parallel-search__web_search"),
            NamedTool("parallel-search__fetch"),
            NamedTool("deepwiki__ask")
        ]
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true),
            approvalHandler: { _ in .approve },
            mcpTools: mcpTools,
            mcpApprovalDefaults: mcpApprovalDefaults(servers: servers, tools: mcpTools)
        )
        let screen = ChatScreen(
            variant: DeepAgentVariant.all[0], agent: agent,
            build: { _, _ in nil }, gate: ApprovalGate(), mcpServers: servers
        )

        let browser = screen.makeMCPBrowser()
        #expect(browser.title == "MCP servers")
        #expect(browser.groups.count == 2)

        let parallel = browser.groups.first { $0.title == "parallel-search" }
        #expect(parallel?.tools.map(\.name).sorted() == ["parallel-search__fetch", "parallel-search__web_search"])
        #expect(parallel?.subtitle?.contains("HTTP") == true)
        #expect(parallel?.subtitle?.contains("approval: Ask") == true)

        let deepwiki = browser.groups.first { $0.title == "deepwiki" }
        #expect(deepwiki?.tools.map(\.name) == ["deepwiki__ask"])
        #expect(deepwiki?.subtitle?.contains("OAuth") == true)
        #expect(deepwiki?.subtitle?.contains("approval: Approve") == true)
    }

    @Test("A server that failed to connect is flagged in its subtitle, not shown as healthy")
    func flagsAFailedServer() {
        let servers = [
            MCPServerConfig(name: "parallel-task-mcp", kind: .http, url: "https://t/mcp", auth: .oauth)
        ]
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        let screen = ChatScreen(
            variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: ApprovalGate(),
            mcpServers: servers,
            mcpStatuses: [
                MCPServerStatus(id: servers[0].id, name: "parallel-task-mcp", toolCount: 0, error: "not signed in")
            ]
        )
        let group = screen.makeMCPBrowser().groups.first { $0.title == "parallel-task-mcp" }
        #expect(group?.subtitle?.contains("⚠ not signed in") == true)
    }

    @Test("With a live runtime, an unsigned OAuth server invites sign-in and resolves as the target")
    func invitesSignInFromMCP() {
        let servers = [MCPServerConfig(name: "parallel-task-mcp", kind: .http, url: "https://t/mcp", auth: .oauth)]
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        let screen = ChatScreen(
            variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: ApprovalGate(),
            mcpServers: servers, mcpRuntime: MCPRuntime(servers: servers)
        )
        let group = screen.makeMCPBrowser().groups.first { $0.title == "parallel-task-mcp" }
        #expect(group?.subtitle?.contains("press r to sign in") == true) // the yellow affordance
        #expect(screen.mcpLoginTarget(screen.makeMCPBrowser()) == servers.first) // resolves as the target
    }

    @Test("Empty config yields an empty browser with a helpful message")
    func emptyConfig() {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        let screen = ChatScreen(
            variant: DeepAgentVariant.all[0], agent: agent,
            build: { _, _ in nil }, gate: ApprovalGate(), mcpServers: []
        )
        let browser = screen.makeMCPBrowser()
        #expect(browser.groups.isEmpty)
        #expect(browser.emptyMessage.contains(".ripple/mcp.json"))
    }
}

@Suite("MCP auth state")
struct MCPAuthStateTests {
    private func http(
        _ name: String = "srv", auth: MCPServerConfig.Auth = .none, headers: [String: String] = [:]
    ) -> MCPServerConfig {
        MCPServerConfig(name: name, kind: .http, url: "https://x/mcp", headers: headers, auth: auth)
    }

    @Test("A plain HTTP server that answered 401 needs sign-in - no `oauth` key required (Claude Code-style)")
    func plainHTTP401NeedsAuth() {
        #expect(
            MCPRuntime.authState(server: http(), statusError: "Authentication required", hasToken: false)
                == .needsAuth
        )
    }

    @Test("A plain HTTP server we reached fine (or failed for a non-auth reason) has nothing to sign into")
    func plainHTTPNotApplicable() {
        #expect(MCPRuntime.authState(server: http(), statusError: nil, hasToken: false) == .notApplicable)
        #expect(MCPRuntime.authState(server: http(), statusError: "Connection refused", hasToken: false) == .notApplicable)
    }

    @Test("A cached token reads as signed in; a fresh 401 with a stale token still needs re-auth")
    func tokenStates() {
        #expect(MCPRuntime.authState(server: http(), statusError: nil, hasToken: true) == .signedIn)
        #expect(
            MCPRuntime.authState(server: http(), statusError: "Authentication required", hasToken: true)
                == .needsAuth
        )
    }

    @Test("A declared OAuth server needs sign-in without a token, signed in with one")
    func declaredOAuth() {
        let oauth = http(auth: .oauth)
        #expect(MCPRuntime.authState(server: oauth, statusError: "not signed in", hasToken: false) == .needsAuth)
        #expect(MCPRuntime.authState(server: oauth, statusError: nil, hasToken: true) == .signedIn)
    }

    @Test("A static Authorization header is header auth, never an OAuth sign-in - even on a 401")
    func headerAuthIsNotOAuth() {
        #expect(
            MCPRuntime.authState(
                server: http(headers: ["Authorization": "Bearer abc"]),
                statusError: "Authentication required", hasToken: false
            ) == .notApplicable
        )
        #expect(MCPRuntime.hasAuthorizationHeader(http(headers: ["authorization": "x"])) == true) // case-insensitive
        #expect(MCPRuntime.hasAuthorizationHeader(http(headers: ["X-Api-Key": "x"])) == false)
    }

    @Test("stdio servers never sign in")
    func stdioNotApplicable() {
        let stdio = MCPServerConfig(name: "fs", kind: .stdio, command: "/bin/echo")
        #expect(
            MCPRuntime.authState(server: stdio, statusError: "Authentication required", hasToken: false)
                == .notApplicable
        )
    }

    @Test("Classifier matches the SDK's 401 message, not a 403 or other failures")
    func classifier() {
        // The swift-sdk maps a 401 with no authorizer to MCPError.internalError("Authentication required").
        #expect(MCPRuntime.isAuthRequiredError("Authentication required") == true)
        #expect(MCPRuntime.isAuthRequiredError("Internal error: Authentication required") == true)
        #expect(MCPRuntime.isAuthRequiredError("Access forbidden") == false) // 403: a sign-in won't fix it
        #expect(MCPRuntime.isAuthRequiredError("not signed in") == false)
        #expect(MCPRuntime.isAuthRequiredError("Connection refused") == false)
        #expect(MCPRuntime.isAuthRequiredError(nil) == false)
    }
}

/// A minimal `AgentTool` with a chosen name, standing in for a loaded MCP tool.
private struct NamedTool: AgentTool {
    let name: String
    init(_ name: String) { self.name = name }
    var description: String { "stub" }
    var parameters: [ToolParameter] { [] }
    func execute(_ arguments: [String: AgentJSON], _ context: ToolContext) async throws -> ToolOutput {
        ToolOutput("ok")
    }
}
