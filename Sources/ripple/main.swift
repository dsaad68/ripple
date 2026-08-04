import ArgumentParser
import Darwin
import DeepAgents
import Foundation

// The `ripple` CLI: a headless front-end to Mispher's deep agent.
//
//   ripple                       interactive REPL (a terminal), or one-shot if stdin is piped
//   ripple -p "prompt"           one-shot, non-interactive run (see HeadlessRun)
//   echo "..." | ripple          one-shot run with the piped text as the prompt
//   ripple chat [...]            interactive Claude-Code-style REPL (DeepAgentREPL)
//   ripple run <scenarios>       TOML/JSON scenario harness (DeepAgentSelfTest)
//   ripple mcp ... / model ...   manage MCP servers / local models
//
// Argument parsing is ArgumentParser-based; the command bodies just call public entry points.

// MARK: - Shared parsing helpers (also used by RippleMCPCommand / tests)

/// The value after a `--flag` in `args`, or nil if the flag is absent / has no value. Kept as a free
/// function because `RippleMCPCommand` parses its passthrough args with it.
func option(_ args: [String], _ flag: String) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

/// The `--resume` request expressed by raw `args`: `--resume <id>` reopens that session; a bare
/// `--resume` (no value, or followed by another flag) picks from this project's past sessions; absent
/// flag is nil. Retained (and unit-tested) as the canonical parse of the resume forms.
func resumeRequest(_ args: [String]) -> ResumeRequest? {
    guard let index = args.firstIndex(of: "--resume") else { return nil }
    let next = index + 1 < args.count ? args[index + 1] : nil
    if let next, !next.hasPrefix("-") { return .id(next) }
    return .pick
}

/// ArgumentParser wants `--flag value`, but two flags historically take an *optional* value:
/// `--sandbox` (bare = failover) and `--resume` (bare = pick from this project). Rewrite a bare
/// occurrence into its canonical valued form so the parser accepts both spellings. A flag already
/// followed by its value is left untouched.
func normalizeOptionalValueFlags(_ args: [String]) -> [String] {
    let sandboxModes: Set = ["off", "failover", "container-only", "containerOnly"]
    var result: [String] = []
    var index = args.startIndex
    while index < args.endIndex {
        let token = args[index]
        result.append(token)
        let nextIndex = args.index(after: index)
        let next = nextIndex < args.endIndex ? args[nextIndex] : nil
        if token == "--sandbox", next == nil || !sandboxModes.contains(next!) {
            result.append("failover")
        } else if token == "--resume", next == nil || next!.hasPrefix("-") {
            result.append(CommonRunOptions.resumePickToken)
        }
        index = nextIndex
    }
    return result
}

/// Launch the interactive REPL from the shared run flags (the bare/`chat` path).
@MainActor
func runChat(_ common: CommonRunOptions) async {
    await DeepAgentREPL.run(
        plannerOverride: common.model,
        logDirectory: common.log,
        sandbox: common.sandbox,
        autoDownload: common.yes,
        resume: common.resumeRequest
    )
}

// MARK: - ExpressibleByArgument conformances

extension OutputFormat: ExpressibleByArgument {
    // `init?(argument:)` comes from ArgumentParser's RawRepresentable default; spell out the value
    // list so help shows the raw spellings (e.g. `stream-json`) rather than the case names.
    static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

extension PermissionMode: ExpressibleByArgument {
    init?(argument: String) {
        switch argument {
        case "ask": self = .ask
        case "auto-reads": self = .autoReads
        case "plan": self = .plan
        case "accept-all": self = .acceptAll
        default: return nil
        }
    }

    static var allValueStrings: [String] { ["ask", "auto-reads", "plan", "accept-all"] }
}

extension SandboxMode: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        switch argument {
        case "off": self = .off
        case "failover": self = .failover
        case "container-only", "containerOnly": self = .containerOnly
        default: return nil
        }
    }

    public static var allValueStrings: [String] { ["off", "failover", "container-only"] }
}

// MARK: - Commands

/// Run flags shared by the interactive `chat` path and the bare/`-p` root invocation.
struct CommonRunOptions: ParsableArguments {
    /// The sentinel `--resume` rewrites to (see ``normalizeOptionalValueFlags``) meaning "pick".
    static let resumePickToken = "\u{0}pick"

    @Option(name: .long, help: "Planner model: a Hugging Face id or a registered remote-model name.")
    var model: String?

    @Option(name: .long, help: "Directory for the JSONL debug transcript.")
    var log: String?

    @Option(name: .long, help: "Container sandbox: off | failover | container-only (bare --sandbox = failover).")
    var sandbox: SandboxMode?

    @Flag(name: [.long, .customLong("download")], help: "Auto-download a missing model instead of prompting.")
    var yes = false

    @Option(name: .long, help: "Resume a session by id (bare --resume picks from this project).")
    var resume: String?

    /// The resume request for the chat path, or nil when `--resume` was not given.
    var resumeRequest: ResumeRequest? {
        guard let resume else { return nil }
        return resume == Self.resumePickToken ? .pick : .id(resume)
    }
}

/// Root command: bare `ripple` (REPL, or one-shot when stdin is piped) and `ripple -p "..."`.
///
/// These commands are plain ``ParsableCommand``s (not ``AsyncParsableCommand``) and expose their work
/// through ``execute()`` rather than `run()`. The reason: under this target's upcoming-feature build
/// settings, an `async` `run()` isn't reliably matched as the `AsyncParsableCommand` witness, so the
/// protocol's default `run()` (which prints help) wins. Parsing/help/validation still come from
/// `ParsableCommand`; the entry point parses, then concretely dispatches to `execute()`.
struct Ripple: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ripple",
        abstract: "On-device deep agent - interactive REPL or one-shot headless runs.",
        discussion: """
        Run `ripple` with no arguments for the interactive REPL. Pass `-p \"...\"` (or pipe text on \
        stdin) for a one-shot, non-interactive run with machine-readable output and explicit \
        permission / tool / sandbox control.

        Ripple       https://github.com/dsaad68/ripple
        Ripple docs  https://ripple.verybad.engineer
        DeepAgents   https://github.com/dsaad68/deepagents-swift
        DeepAgents docs  https://deepagents-swift.verybad.engineer
        """,
        version: RippleVersion.versionLine,
        subcommands: [Chat.self, RunScenarios.self, MCPCommandWrapper.self, ModelCommandWrapper.self]
    )

    @OptionGroup var common: CommonRunOptions

    @Option(name: [.customShort("p"), .customLong("print")], help: "Prompt for a one-shot non-interactive run.")
    var prompt: String?

    @Option(name: .customLong("output-format"), help: "text | json | stream-json (headless only; default text).")
    var outputFormat: OutputFormat?

    @Option(name: .customLong("permission-mode"), help: "ask | auto-reads | plan | accept-all (headless approvals).")
    var permissionMode: PermissionMode?

    @Option(name: .customLong("allow-tool"), help: "Auto-approve this tool, no prompt (repeatable).")
    var allowTool: [String] = []

    @Option(name: .customLong("deny-tool"), help: "Auto-reject this tool (repeatable).")
    var denyTool: [String] = []

    @Option(name: .customLong("disable-middleware"), help: "Turn off a capability middleware by id (repeatable).")
    var disableMiddleware: [String] = []

    @Option(name: .customLong("sandbox-image"), help: "OCI image the sandbox container runs.")
    var sandboxImage: String?

    func execute() async throws {
        // Headless when an explicit prompt is given, or when stdin is piped (a bare `echo ... | ripple`).
        let headless = prompt != nil || isatty(STDIN_FILENO) == 0
        guard headless else {
            // No silent no-ops: headless-only flags don't reach the REPL, so reject them here instead
            // of accepting and ignoring them. (`--resume` and the shared run flags do apply to chat.)
            let stray = headlessOnlyFlagsInUse()
            guard stray.isEmpty else {
                throw ValidationError(
                    "\(stray.joined(separator: ", ")) appl\(stray.count == 1 ? "ies" : "y") only to a "
                        + "headless run (-p or piped stdin)."
                )
            }
            await runChat(common)
            return
        }
        // `--resume` only means something for the interactive REPL; headless is a stateless one-shot, so
        // reject it rather than silently ignoring it.
        guard common.resume == nil else {
            throw ValidationError("--resume applies to the interactive REPL, not a headless (-p) run.")
        }
        var options = HeadlessOptions()
        options.promptArg = prompt
        options.outputFormat = outputFormat ?? .text
        options.permissionMode = permissionMode ?? .ask
        options.model = common.model
        options.allowTools = allowTool
        options.denyTools = denyTool
        options.disableMiddleware = disableMiddleware
        options.sandbox = common.sandbox
        options.sandboxImage = sandboxImage
        options.logDirectory = common.log
        options.autoDownload = common.yes
        let code = await HeadlessRun.run(options)
        if code != 0 { throw ExitCode(code) }
    }

    /// The headless-only flags the caller actually set, by name. Used to reject them on the interactive
    /// path (the REPL doesn't consume them, so accepting them silently would be a no-op). The shared run
    /// flags (`--model`, `--log`, `--sandbox`, `--yes`, `--resume`) are intentionally excluded.
    func headlessOnlyFlagsInUse() -> [String] {
        var flags: [String] = []
        if outputFormat != nil { flags.append("--output-format") }
        if permissionMode != nil { flags.append("--permission-mode") }
        if !allowTool.isEmpty { flags.append("--allow-tool") }
        if !denyTool.isEmpty { flags.append("--deny-tool") }
        if !disableMiddleware.isEmpty { flags.append("--disable-middleware") }
        if sandboxImage != nil { flags.append("--sandbox-image") }
        return flags
    }
}

/// `ripple chat`: the interactive REPL (also the default for a bare `ripple` in a terminal).
struct Chat: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Interactive deep-agent REPL (needs a terminal).")

    @OptionGroup var common: CommonRunOptions

    func execute() async { await runChat(common) }
}

/// `ripple run <scenarios>`: the headless scenario harness.
struct RunScenarios: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Headless TOML/JSON scenario harness."
    )

    @Argument(help: "A scenario .json file or a directory of them.")
    var scenarios: String

    @Option(name: .long, help: "Output directory for traces + manifest.")
    var out = "deepagent-runs/latest"

    func execute() async { await DeepAgentSelfTest.run(scenariosPath: scenarios, outDirPath: out) }
}

/// `ripple mcp ...`: passthrough to the existing MCP command (which parses its own subcommands).
struct MCPCommandWrapper: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp", abstract: "Manage MCP servers (mcp -h for details)."
    )

    @Argument(parsing: .captureForPassthrough)
    var args: [String] = []

    func execute() async { await RippleMCPCommand.run(args) }
}

/// `ripple model ...` (alias `models`): passthrough to the existing model command.
struct ModelCommandWrapper: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model", abstract: "Download / manage local models (model -h for details).",
        aliases: ["models"]
    )

    @Argument(parsing: .captureForPassthrough)
    var args: [String] = []

    func execute() async { await RippleModelCommand.run(args) }
}

// MARK: - Entry point

// ripple shares DeepAgents with the Mispher app; stamp the CLI's identity before any MCP / Keychain
// use so the macOS Keychain prompt (and the OAuth consent / MCP client name) read "Ripple" instead of
// the framework's Mispher default. The app leaves these at their defaults.
DeepAgentsIdentity.keychainService = "ai.ripple.mcp.oauth"
DeepAgentsIdentity.productName = "Ripple"
DeepAgentsIdentity.oauthClientID = "ripple"

// Parse the normalized args (ArgumentParser handles help/validation, throwing on `-h` or bad input),
// then dispatch on the concrete command type to its async `execute()`. See the note on ``Ripple`` for
// why we drive `execute()` ourselves instead of relying on `AsyncParsableCommand.run()`.
let arguments = normalizeOptionalValueFlags(Array(CommandLine.arguments.dropFirst()))
do {
    var command = try Ripple.parseAsRoot(arguments)
    switch command {
    case let root as Ripple: try await root.execute()
    case let chat as Chat: await chat.execute()
    case let scenarios as RunScenarios: await scenarios.execute()
    case let mcp as MCPCommandWrapper: await mcp.execute()
    case let model as ModelCommandWrapper: await model.execute()
    default: try command.run() // ArgumentParser built-ins (e.g. the `help` subcommand)
    }
} catch {
    Ripple.exit(withError: error)
}
