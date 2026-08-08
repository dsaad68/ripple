@testable import DeepAgents
@testable import DeepAgentsMLX
import Foundation
@testable import ripple
import Testing

/// The `/config` Lazy Tools choices have to survive quitting ripple. They live in `settings.json`
/// under `toolPolicy`, so this drives the real save/load path (`RippleAgentConfig`) in a temp project
/// rather than trusting the `Codable` conformance by inspection.
@MainActor
struct LazyToolsPersistenceTests {
    private func tempProject() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ripple-lazytools-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var tiered: AgentToolPolicy {
        AgentToolPolicy(
            toolSearch: true,
            auxiliaryMiddleware: ["git", "text"],
            auxiliaryTools: ["curl"],
            coreMCPServers: ["deepwiki"],
            toolSearchModel: ToolSearchModel.colbert350m8bit.repoID,
            toolSearchLimit: 8
        )
    }

    @Test("Every lazy-tool field is encoded into settings.json, not silently dropped")
    func fieldsReachTheFile() throws {
        let project = tempProject()
        try RippleAgentConfig.savePolicy(tiered, workingDirectory: project)

        let url = RippleAgentConfig.projectSettingsURL(workingDirectory: project)
        let text = try String(contentsOf: url, encoding: .utf8)
        for key in ["toolSearch", "auxiliaryMiddleware", "auxiliaryTools", "coreMCPServers",
                    "toolSearchModel", "toolSearchLimit"] {
            #expect(text.contains(key), "settings.json is missing \(key):\n\(text)")
        }
    }

    @Test("A saved policy reloads with its tiers intact")
    func roundTrips() throws {
        let project = tempProject()
        try RippleAgentConfig.savePolicy(tiered, workingDirectory: project)

        let reloaded = RippleAgentConfig.loadPolicy(workingDirectory: project)
        #expect(reloaded.toolSearch)
        #expect(reloaded.auxiliaryMiddleware == ["git", "text"])
        #expect(reloaded.auxiliaryTools == ["curl"])
        #expect(reloaded.coreMCPServers == ["deepwiki"])
        #expect(reloaded.toolSearchModel == ToolSearchModel.colbert350m8bit.repoID)
        #expect(reloaded.toolSearchLimit == 8)
    }

    @Test("Saving the policy leaves the file's other keys alone")
    func preservesSiblings() throws {
        let project = tempProject()
        let url = RippleAgentConfig.projectSettingsURL(workingDirectory: project)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try #"{"selectedModel":"some/model"}"#.write(to: url, atomically: true, encoding: .utf8)

        try RippleAgentConfig.savePolicy(tiered, workingDirectory: project)
        #expect(RippleAgentConfig.loadSelectedModel(workingDirectory: project) == "some/model")
    }

    @Test("The reloaded policy still expands to the same auxiliary set")
    func expansionSurvivesTheRoundTrip() throws {
        // The end of the chain that actually matters: a tier is only "applied" if it comes back out of
        // `expand()` as an auxiliary tool name for the agent.
        let project = tempProject()
        try RippleAgentConfig.savePolicy(tiered, workingDirectory: project)

        let auxiliary = RippleAgentConfig.loadPolicy(workingDirectory: project)
            .expand().auxiliaryToolNames
        #expect(auxiliary.contains("git_log"))
        #expect(auxiliary.contains("curl"))
        #expect(!auxiliary.contains("read_file"))
    }
}
