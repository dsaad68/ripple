@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
import MLXLMCommon
@testable import ripple
import Testing

/// Editing the container image inline on the `/config` Container row: the begin / commit / cancel flow
/// and the `e` (edit) / `x` (reset-to-default) keys. The commit normalizes the typed value - a blank
/// entry clears the override so it falls back to ``AppleContainerSandbox/defaultImage``.
@MainActor
struct ContainerImageEditTests {
    private func makeScreen(policy: AgentToolPolicy = .init()) -> ChatScreen {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        let screen = ChatScreen(
            variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil },
            gate: ApprovalGate(), policy: policy
        )
        var editor = ConfigEditor(policy: policy)
        editor.tab = .sandbox // the container row lives on the Sandbox tab
        editor.index = editor.rows.firstIndex { $0.isContainer } ?? 0
        screen.config = editor
        return screen
    }

    @Test("beginImageEdit loads the current override (empty for the built-in default)")
    func beginLoadsCurrent() {
        let onDefault = makeScreen()
        onDefault.beginImageEdit()
        #expect(onDefault.configEditingImage)
        #expect(onDefault.inputText == "") // default -> empty field, not the resolved default image

        let onCustom = makeScreen(policy: AgentToolPolicy(sandboxImage: "img:existing"))
        onCustom.beginImageEdit()
        #expect(onCustom.inputText == "img:existing")
    }

    @Test("Committing a value stores it; committing blank clears back to the default")
    func commitNormalizes() {
        let screen = makeScreen()
        screen.beginImageEdit()
        screen.setInput("  alpine:3.20  ") // surrounding whitespace is trimmed
        screen.commitImageEdit()
        #expect(screen.config?.policy.sandboxImage == "alpine:3.20")
        #expect(!screen.configEditingImage)
        #expect(screen.inputText == "") // the shared input buffer is cleared after commit

        screen.beginImageEdit()
        screen.setInput("   ") // whitespace-only -> clear the override
        screen.commitImageEdit()
        #expect(screen.config?.policy.sandboxImage == nil)
    }

    @Test("Cancel leaves the working policy untouched")
    func cancelKeepsPolicy() {
        let screen = makeScreen(policy: AgentToolPolicy(sandboxImage: "img:keep"))
        screen.beginImageEdit()
        screen.setInput("img:discarded")
        screen.cancelImageEdit()
        #expect(!screen.configEditingImage)
        #expect(screen.config?.policy.sandboxImage == "img:keep")
    }

    @Test("On the Container row, 'e' begins editing and 'x' resets to the default")
    func keysOnContainerRow() {
        let screen = makeScreen(policy: AgentToolPolicy(sandboxImage: "img:custom"))
        screen.handleConfigByte(0x78) // 'x' -> reset to default
        #expect(screen.config?.policy.sandboxImage == nil)
        screen.handleConfigByte(0x65) // 'e' -> begin editing
        #expect(screen.configEditingImage)
    }

    @Test("The edit keys do nothing on a non-Container row")
    func keysIgnoredElsewhere() throws {
        let screen = makeScreen(policy: AgentToolPolicy(sandboxImage: "img:custom"))
        screen.config?.tab = .capabilities // git lives on the Capabilities tab, not Sandbox
        let gitIndex = try #require(screen.config?.rows.firstIndex { $0.id == "git" })
        screen.config?.index = gitIndex
        screen.handleConfigByte(0x78) // 'x' is a no-op off the Container row
        #expect(screen.config?.policy.sandboxImage == "img:custom")
        screen.handleConfigByte(0x65) // 'e' is a no-op off the Container row
        #expect(!screen.configEditingImage)
    }
}
