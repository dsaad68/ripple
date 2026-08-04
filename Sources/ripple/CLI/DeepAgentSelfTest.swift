import AppKit
import DeepAgents
import DeepAgentsMLX
import Foundation
import MLX

/// Headless runner for the DeepAgent scenario harness, driven by `MISPHER_SELFTEST=deepagent`
/// from `MispherMain`. It reads TOML-derived JSON scenario specs (`MISPHER_SCENARIOS`), builds
/// each agent topology from its spec, runs the prompts against the real on-device models with
/// fixture screenshots/clipboard (so runs are deterministic and need no Screen Recording
/// permission), and writes one JSONL trace per scenario plus a `manifest.json` the Python
/// analyzer reads. Mirrors `AudioSelfTest`: a Task driven off `MispherMain`, logging to stderr.
@MainActor
public enum DeepAgentSelfTest {
    /// A decoded scenario plus the directory it came from, for resolving relative fixture paths.
    private struct Spec {
        let scenario: DeepAgentScenario
        let baseDirectory: URL
    }

    /// Run from the environment (`MISPHER_SCENARIOS`, `MISPHER_DEEPAGENT_OUT`).
    public static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard let scenariosPath = env["MISPHER_SCENARIOS"], !scenariosPath.isEmpty else {
            log("set MISPHER_SCENARIOS to a scenario .json file or a directory of them")
            return
        }
        await run(
            scenariosPath: scenariosPath,
            outDirPath: env["MISPHER_DEEPAGENT_OUT"] ?? "deepagent-runs/latest"
        )
    }

    /// Run an explicit scenarios path (a `.json` file or a directory of them), writing one JSONL
    /// trace per scenario plus a `manifest.json` under `outDirPath`. The `deepagent run` CLI calls
    /// this.
    public static func run(scenariosPath: String, outDirPath: String) async {
        let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)

        let specs = loadSpecs(at: scenariosPath)
        guard !specs.isEmpty else {
            log("no scenario specs found at \(scenariosPath)")
            return
        }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        log("running \(specs.count) scenario(s) -> \(outDir.path)")

        let manager = MlxModelLoader()
        var records: [Manifest.Record] = []
        for spec in specs {
            let record = await runScenario(spec, manager: manager, outDir: outDir)
            records.append(record)
            // Free the Metal buffer cache between scenarios so resident weights/generations don't
            // accumulate unified memory across the run (the OOM guard the integration suite uses).
            MLX.Memory.clearCache()
        }

        writeManifest(Manifest(scenarios: records), to: outDir)
        log("done - manifest at \(outDir.appendingPathComponent("manifest.json").path)")
    }

    // MARK: - Per scenario

    private static func runScenario(
        _ spec: Spec, manager: MlxModelLoader, outDir: URL
    ) async -> Manifest.Record {
        let scenario = spec.scenario
        let agentSpec = scenario.agent
        let modelIDs = [agentSpec.model] + agentSpec.subagents.compactMap(\.model)
        let subagentSummary = agentSpec.subagents.map { "\($0.name)(\($0.model ?? "inherit"))" }

        func record(success: Bool, skipped: Bool, note: String?, trace: String?, toolsUsed: [String])
            -> Manifest.Record {
            Manifest.Record(
                id: scenario.id, model: agentSpec.model, subagents: subagentSummary,
                middleware: agentSpec.middleware, tools: agentSpec.tools, turns: scenario.prompts.turns,
                trace: trace, success: success, skipped: skipped, note: note,
                toolsUsed: toolsUsed, expect: scenario.expect
            )
        }

        // Skip cleanly (no surprise multi-GB download) when a referenced model isn't cached.
        let missing = modelIDs.filter { !ModelCache.isDownloaded($0) }
        guard missing.isEmpty else {
            log("[\(scenario.id)] SKIP - models not downloaded: \(missing.joined(separator: ", "))")
            return record(
                success: false, skipped: true,
                note: "Models not downloaded: \(missing.joined(separator: ", "))",
                trace: nil, toolsUsed: []
            )
        }

        // Per-scenario directory holds this run's single JSONL trace and its filesystem scratch.
        let scenarioDir = outDir.appendingPathComponent(scenario.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: scenarioDir, withIntermediateDirectories: true)

        seedClipboard(scenario.fixtures?.clipboard)
        let screenCapture = fixtureCapture(scenario.fixtures, base: spec.baseDirectory)
        let messageLog = JSONLMessageLog(directory: scenarioDir)
        let memory = InMemoryCheckpointer()

        let agent: ReactAgent
        do {
            agent = try await ScenarioBuilder.build(
                scenario, manager: manager,
                context: ScenarioBuilder.Context(
                    screenCapture: screenCapture,
                    localRoot: scenarioDir.appendingPathComponent("fs", isDirectory: true),
                    messageLog: messageLog, memory: memory
                )
            )
        } catch {
            log("[\(scenario.id)] ERROR building agent: \(error)")
            return record(
                success: false, skipped: false, note: "Build error: \(error)",
                trace: nil, toolsUsed: []
            )
        }

        var allOK = true
        var toolsUsed: [String] = []
        for (index, turn) in scenario.prompts.turns.enumerated() {
            log("[\(scenario.id)] turn \(index + 1)/\(scenario.prompts.turns.count): \(turn)")
            let (ok, tools) = await runTurn(agent: agent, prompt: turn, threadId: scenario.id)
            allOK = allOK && ok
            toolsUsed += tools
        }

        let trace = traceFile(in: scenarioDir).map { "\(scenario.id)/\($0.lastPathComponent)" }
        log("[\(scenario.id)] \(allOK ? "OK" : "FAILED") - tools: \(toolsUsed.isEmpty ? "none" : toolsUsed.joined(separator: ", "))")
        return record(success: allOK, skipped: false, note: nil, trace: trace, toolsUsed: toolsUsed)
    }

    /// Run one turn, marshaling the agent's events through an `AsyncStream` (as `askAgent` does)
    /// so the tally is mutated on this actor and the `@Sendable` run closure only yields.
    private static func runTurn(
        agent: ReactAgent, prompt: String, threadId: String
    ) async -> (ok: Bool, tools: [String]) {
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let runTask = Task.detached {
            let ok = await agent.run([.human(prompt)], threadId: threadId) { continuation.yield($0) }
            continuation.finish()
            return ok
        }
        var tools: [String] = []
        for await event in events {
            switch event {
            case .toolStarted(let name, _): tools.append(name)
            default: break
            }
        }
        return await (runTask.value, tools)
    }

    // MARK: - Fixtures

    private static func seedClipboard(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func fixtureCapture(
        _ fixtures: DeepAgentScenario.Fixtures?, base: URL
    ) -> FixtureScreenCapture {
        let windows = (fixtures?.windows ?? []).map {
            FixtureScreenCapture.Window(name: $0.name, url: resolve($0.png, base: base))
        }
        let screen = fixtures?.screen.map {
            FixtureScreenCapture.Window(name: "screen", url: resolve($0, base: base))
        }
        return FixtureScreenCapture(windows: windows, screen: screen)
    }

    /// Resolve a fixture path: absolute as-is, otherwise relative to the scenario file's directory.
    /// (The wrapper already absolutizes paths; this keeps hand-written specs working too.)
    private static func resolve(_ path: String, base: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    }

    // MARK: - Loading specs

    private static func loadSpecs(at path: String) -> [Spec] {
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }

        let files: [URL]
        if isDirectory.boolValue {
            files = ((try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            files = [url]
        }

        let decoder = JSONDecoder()
        return files.compactMap { file in
            guard let data = try? Data(contentsOf: file) else {
                log("could not read \(file.lastPathComponent)")
                return nil
            }
            do {
                let scenario = try decoder.decode(DeepAgentScenario.self, from: data)
                return Spec(scenario: scenario, baseDirectory: file.deletingLastPathComponent())
            } catch {
                log("could not decode \(file.lastPathComponent): \(error)")
                return nil
            }
        }
    }

    /// The single `.jsonl` trace `JSONLMessageLog` wrote into a scenario's directory.
    private static func traceFile(in directory: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "jsonl" }
    }

    // MARK: - Manifest

    /// The run manifest the Python analyzer reads: one record per scenario, with the resolved
    /// topology, the trace path, success/skip status, and the scenario's `expect` block verbatim.
    private struct Manifest: Encodable {
        let scenarios: [Record]

        struct Record: Encodable {
            let id: String
            let model: String
            let subagents: [String]
            let middleware: [String]
            let tools: [String]
            let turns: [String]
            let trace: String?
            let success: Bool
            let skipped: Bool
            let note: String?
            let toolsUsed: [String]
            let expect: [String: ScalarValue]?
        }
    }

    private static func writeManifest(_ manifest: Manifest, to outDir: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: outDir.appendingPathComponent("manifest.json"))
    }

    private nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
