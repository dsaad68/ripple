@testable import DeepAgents
import Foundation
@testable import ripple
import Testing

/// The working line's phase labels: a cold model (re)load and the prompt prefill are long silent
/// stretches that used to both read as "working…" - the line now says which one the user is in.
@MainActor
struct WorkingLinePhaseTests {
    private func makeScreen(modelLoadStatus: @escaping @MainActor () -> String? = { nil }) -> ChatScreen {
        let agent = RippleDeepAgent.make(textModel: FakeChatModel(answer: "x"))
        let screen = ChatScreen(
            variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil },
            gate: ApprovalGate(), modelLoadStatus: modelLoadStatus
        )
        screen.running = true
        screen.turnStart = Date()
        return screen
    }

    private func plainOverlay(_ screen: ChatScreen) -> String {
        screen.overlayLines(width: 100).map(\.text).joined(separator: "\n")
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    @Test("A cold model load is labeled as loading, not as prompt work")
    func modelLoadLabeled() {
        let screen = makeScreen(modelLoadStatus: { "Ornith 1.0 9B" })
        #expect(plainOverlay(screen).contains("loading Ornith 1.0 9B into memory…"))
    }

    @Test("Before anything streams, the silent stretch is labeled as the prefill")
    func prefillLabeled() {
        let screen = makeScreen()
        #expect(plainOverlay(screen).contains("prefilling the prompt…"))
    }

    @Test("Once the turn produces output, the label returns to working")
    func generationLabeled() {
        let screen = makeScreen()
        let assistant = Assistant()
        assistant.consume(.reasoningToken("thinking")) // reasoning counts as output too
        screen.liveAssistant = assistant
        let overlay = plainOverlay(screen)
        #expect(overlay.contains("working…"))
        #expect(!overlay.contains("prefilling the prompt"))
    }
}
