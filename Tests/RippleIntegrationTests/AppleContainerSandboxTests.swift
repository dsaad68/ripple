@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
import MLXLMCommon
@testable import ripple
import Testing

// The Apple Container sandbox + `container_shell` middleware. The `container` CLI is macOS-only and
// can't run in CI, so the sandbox takes an injectable runner: these assert the exact `container`
// argv (the bind-mount, workdir, exec form) without a real `container`, plus the unavailable-sandbox
// fall-through (failover vs container-only), the `/config` settings model, and policy persistence.

/// Records the `container` subcommand argv the sandbox would run, and returns a canned result (or
/// throws, to simulate the tool being unavailable).
private final class FakeContainer: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private let shouldThrow: Bool
    private let result: @Sendable ([String]) -> ProcessRunner.Result

    init(
        shouldThrow: Bool = false,
        result: @escaping @Sendable ([String]) -> ProcessRunner.Result = { _ in
            ProcessRunner.Result(stdout: "", stderr: "", status: 0, timedOut: false)
        }
    ) {
        self.shouldThrow = shouldThrow
        self.result = result
    }

    var runner: AppleContainerSandbox.Runner {
        { args, _, _, _ in
            self.lock.withLock { self.calls.append(args) }
            if self.shouldThrow { throw FakeError.boom }
            return self.result(args)
        }
    }

    var recorded: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
}

private enum FakeError: Error { case boom }

private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mispher-container-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("AppleContainerSandbox")
struct AppleContainerSandboxTests {
    @Test("The container name is deterministic and stable for a working folder")
    func nameIsStable() {
        let root = WorkspaceRoot(rootURL: makeTempDir())
        let a = AppleContainerSandbox.containerName(for: root)
        let b = AppleContainerSandbox.containerName(for: WorkspaceRoot(rootURL: root.rootURL))
        #expect(a == b)
        #expect(a.hasPrefix("mispher-"))
    }

    @Test("ensureRunning starts the service then runs the image with the folder bind-mounted")
    func bringsUpWithMount() async throws {
        let fake = FakeContainer()
        let sandbox = AppleContainerSandbox(root: WorkspaceRoot(rootURL: makeTempDir()), image: "img:test", run: fake.runner)
        try await sandbox.ensureRunning()

        let calls = fake.recorded
        #expect(calls.count == 2)
        #expect(calls.first == ["system", "start"])
        #expect(calls.last == [
            "run", "-d", "--name", sandbox.name,
            "--volume", "\(sandbox.root.rootURL.path):/workspace",
            "--workdir", "/workspace", "img:test", "tail", "-f", "/dev/null"
        ])
    }

    @Test("ensureRunning is idempotent - the container is created once per session")
    func idempotent() async throws {
        let fake = FakeContainer()
        let sandbox = AppleContainerSandbox(root: WorkspaceRoot(rootURL: makeTempDir()), image: "img", run: fake.runner)
        try await sandbox.ensureRunning()
        try await sandbox.ensureRunning()
        #expect(fake.recorded.count == 2) // not repeated
    }

    @Test("exec runs the command via /bin/sh -c inside the container at /workspace")
    func execForm() async throws {
        let fake = FakeContainer()
        let sandbox = AppleContainerSandbox(root: WorkspaceRoot(rootURL: makeTempDir()), image: "img", run: fake.runner)
        _ = try await sandbox.exec("echo hi", timeout: 5)
        #expect(fake.recorded.last == ["exec", "--workdir", "/workspace", sandbox.name, "/bin/sh", "-c", "echo hi"])
    }

    @Test("A missing/unavailable container surfaces as SandboxUnavailableError")
    func unavailableThrows() async {
        let fake = FakeContainer(shouldThrow: true)
        let sandbox = AppleContainerSandbox(root: WorkspaceRoot(rootURL: makeTempDir()), image: "img", run: fake.runner)
        await #expect(throws: SandboxUnavailableError.self) { try await sandbox.ensureRunning() }
    }
}

@Suite("ContainerShellMiddleware")
struct ContainerShellMiddlewareTests {
    private func tool(_ middleware: ContainerShellMiddleware) -> any AgentTool {
        middleware.tools.first { $0.name == "container_shell" }!
    }

    @Test("Exposes a single container_shell tool")
    func exposesTool() {
        let middleware = ContainerShellMiddleware(root: WorkspaceRoot(rootURL: makeTempDir()))
        #expect(middleware.name == "container")
        #expect(middleware.tools.map(\.name) == ["container_shell"])
    }

    @Test("ShellGuard still hard-blocks catastrophic commands before touching the sandbox")
    func blocksDangerous() async throws {
        let fake = FakeContainer()
        let root = WorkspaceRoot(rootURL: makeTempDir())
        let middleware = ContainerShellMiddleware(
            sandbox: AppleContainerSandbox(root: root, image: "img", run: fake.runner), root: root, mode: .failover
        )
        let out = try await tool(middleware).execute(["command": .string("sudo rm -rf /")], ToolContext())
        #expect(out.content.contains("Blocked by the shell safety policy"))
        #expect(fake.recorded.isEmpty) // the sandbox was never started
    }

    @Test("failover runs the command in the local shell when the sandbox is unavailable")
    func failoverRunsLocally() async throws {
        let root = WorkspaceRoot(rootURL: makeTempDir())
        let sandbox = AppleContainerSandbox(root: root, image: "img", run: FakeContainer(shouldThrow: true).runner)
        let middleware = ContainerShellMiddleware(sandbox: sandbox, root: root, mode: .failover)
        let out = try await tool(middleware).execute(["command": .string("echo failover-OK")], ToolContext())
        #expect(out.content.contains("failover-OK")) // it actually ran locally
        #expect(out.content.contains("Sandbox unavailable"))
    }

    @Test("containerOnly refuses and never runs the command when the sandbox is unavailable")
    func containerOnlyRefuses() async throws {
        let root = WorkspaceRoot(rootURL: makeTempDir())
        let sandbox = AppleContainerSandbox(root: root, image: "img", run: FakeContainer(shouldThrow: true).runner)
        let middleware = ContainerShellMiddleware(sandbox: sandbox, root: root, mode: .containerOnly)
        let out = try await tool(middleware).execute(["command": .string("echo ran-marker")], ToolContext())
        #expect(out.content.contains("container only"))
        #expect(!out.content.contains("ran-marker")) // the command was not executed
    }
}

@Suite("AgentToolPolicy sandbox fields")
struct AgentToolPolicySandboxTests {
    @Test("sandbox + sandboxImage round-trip through JSON")
    func roundTrips() throws {
        let policy = AgentToolPolicy(sandbox: .containerOnly, sandboxImage: "img:1")
        let decoded = try JSONDecoder().decode(AgentToolPolicy.self, from: JSONEncoder().encode(policy))
        #expect(decoded == policy)
    }

    @Test("Older JSON without the sandbox fields decodes to the off default")
    func toleratesMissing() throws {
        let decoded = try JSONDecoder().decode(AgentToolPolicy.self, from: Data(#"{"approvals":{}}"#.utf8))
        #expect(decoded.sandbox == .off)
        #expect(decoded.sandboxImage == nil)
    }

    @Test("SandboxMode.isEnabled is false only for off")
    func enabledFlag() {
        #expect(SandboxMode.off.isEnabled == false)
        #expect(SandboxMode.failover.isEnabled)
        #expect(SandboxMode.containerOnly.isEnabled)
    }
}

@Suite("RippleAgentConfig.savePolicy")
struct RippleSavePolicyTests {
    @Test("savePolicy then loadPolicy round-trips through .ripple/tool-policy.json")
    func savesAndLoads() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let policy = AgentToolPolicy(disabledMiddleware: ["web"], sandbox: .failover, sandboxImage: "img:x")
        try RippleAgentConfig.savePolicy(policy, workingDirectory: dir)
        #expect(RippleAgentConfig.loadPolicy(workingDirectory: dir) == policy)
    }
}

@Suite("ConfigEditor")
struct ConfigEditorTests {
    @Test("Toggling the container row cycles off -> failover -> container-only -> off")
    func cyclesSandbox() throws {
        var editor = ConfigEditor(policy: AgentToolPolicy())
        editor.tab = .sandbox // the container row lives on the Sandbox tab
        editor.index = try #require(editor.rows.firstIndex { $0.isContainer })
        #expect(editor.policy.sandbox == .off)
        editor.toggle(); #expect(editor.policy.sandbox == .failover)
        editor.toggle(); #expect(editor.policy.sandbox == .containerOnly)
        editor.toggle(); #expect(editor.policy.sandbox == .off)
    }

    @Test("Toggling a normal capability flips its disabledMiddleware membership")
    func togglesCapability() throws {
        var editor = ConfigEditor(policy: AgentToolPolicy())
        editor.tab = .capabilities // the capability rows live on the Capabilities tab
        let index = try #require(editor.rows.firstIndex { $0.id == "git" })
        editor.index = index
        #expect(editor.isOn(editor.rows[index])) // on by default
        editor.toggle()
        #expect(editor.policy.disabledMiddleware.contains("git"))
        #expect(!editor.isOn(editor.rows[index]))
        editor.toggle()
        #expect(!editor.policy.disabledMiddleware.contains("git"))
    }

    @Test("Container-only locks the local shell off and non-toggleable")
    func containerOnlyLocksShell() throws {
        var editor = ConfigEditor(policy: AgentToolPolicy(sandbox: .containerOnly))
        editor.tab = .capabilities // the shell row lives on the Capabilities tab
        let shellRow = try #require(editor.rows.first { $0.id == "shell" })
        #expect(editor.isLocked(shellRow))
        #expect(!editor.isOn(shellRow))
        #expect(editor.stateLabel(shellRow) == "off - container only")
        editor.index = try #require(editor.rows.firstIndex { $0.id == "shell" })
        editor.toggle() // locked -> no-op, and it never touches disabledMiddleware
        #expect(editor.policy.disabledMiddleware.isEmpty)
        #expect(!editor.isOn(shellRow))
    }

    @Test("Failover locks the local shell on and non-toggleable")
    func failoverLocksShellOn() throws {
        var editor = ConfigEditor(policy: AgentToolPolicy(sandbox: .failover))
        editor.tab = .capabilities // the shell row lives on the Capabilities tab
        let shellRow = try #require(editor.rows.first { $0.id == "shell" })
        #expect(editor.isLocked(shellRow))
        #expect(editor.isOn(shellRow))
        #expect(editor.stateLabel(shellRow) == "on - fail over")
        editor.index = try #require(editor.rows.firstIndex { $0.id == "shell" })
        editor.toggle() // locked -> no-op
        #expect(editor.policy.disabledMiddleware.isEmpty)
        #expect(editor.isOn(shellRow))
    }

    @Test("With the sandbox off, the local shell is user-toggleable")
    func offModeShellToggleable() throws {
        var editor = ConfigEditor(policy: AgentToolPolicy())
        editor.tab = .capabilities // the shell row lives on the Capabilities tab
        let shellRow = try #require(editor.rows.first { $0.id == "shell" })
        #expect(!editor.isLocked(shellRow))
        #expect(editor.isOn(shellRow))
        editor.index = try #require(editor.rows.firstIndex { $0.id == "shell" })
        editor.toggle()
        #expect(editor.policy.disabledMiddleware.contains("shell"))
        #expect(!editor.isOn(shellRow))
    }

    @Test("The Container row reports the resolved image")
    func reportsContainerImage() {
        #expect(ConfigEditor(policy: AgentToolPolicy()).containerImage == AppleContainerSandbox.defaultImage)
        #expect(ConfigEditor(policy: AgentToolPolicy(sandboxImage: "img:custom")).containerImage == "img:custom")
    }
}

@Suite("Sandbox shell governance")
struct SandboxShellGovernanceTests {
    private func deepAgentTools(sandbox: SandboxMode, disabled: Set<String> = []) -> [String] {
        RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true),
            approvalHandler: { _ in .approve },
            policy: AgentToolPolicy(disabledMiddleware: disabled, sandbox: sandbox)
        ).tools.map(\.name)
    }

    @Test("localShellEnabled follows the sandbox governance")
    func localShellGovernance() {
        #expect(AgentToolPolicy().localShellEnabled) // off, not disabled
        #expect(!AgentToolPolicy(disabledMiddleware: ["shell"]).localShellEnabled) // off + disabled
        #expect(AgentToolPolicy(sandbox: .failover).localShellEnabled) // failover forces on
        #expect(AgentToolPolicy(disabledMiddleware: ["shell"], sandbox: .failover).localShellEnabled)
        #expect(!AgentToolPolicy(sandbox: .containerOnly).localShellEnabled) // container-only forces off
    }

    @Test("Container-only drops the local shell but keeps container_shell")
    func dropsLocalShell() {
        let tools = deepAgentTools(sandbox: .containerOnly)
        #expect(!tools.contains("shell"))
        #expect(tools.contains("container_shell"))
    }

    @Test("Failover keeps both shells, forcing the local one on even past a stale disable")
    func failoverForcesShellOn() {
        let tools = deepAgentTools(sandbox: .failover, disabled: ["shell"])
        #expect(tools.contains("shell"))
        #expect(tools.contains("container_shell"))
    }

    @Test("With the sandbox off, a disabled shell stays dropped")
    func offModeRespectsDisable() {
        #expect(!deepAgentTools(sandbox: .off, disabled: ["shell"]).contains("shell"))
        #expect(deepAgentTools(sandbox: .off).contains("shell")) // default: on
    }
}
