@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
import MLXLMCommon
@testable import ripple
import Testing

/// Picking a file from the `@` inline adder keeps the `@` sigil so the insert stays a styled mention
/// chip (and the agent sees `@path`), and the input highlighter renders `@file` tokens distinctly.
@MainActor
struct FileMentionTests {
    private func makeScreen() -> ChatScreen {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        return ChatScreen(variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: ApprovalGate())
    }

    @Test("Selecting a file keeps the @ and inserts the path with a trailing space")
    func selectFileKeepsAtSigil() {
        let screen = makeScreen()
        screen.cwdFiles = ["src/foo.swift", "README.md"]
        screen.setInput("look at @foo") // cursor at the end, inside the @foo token

        screen.selectFile()

        #expect(screen.inputText == "look at @src/foo.swift ")
        #expect(screen.cursor == screen.input.count) // caret lands after the trailing space
    }

    @Test("@file tokens highlight as a distinct mention; plain words stay plain")
    func highlightRoutesMentionsThroughMentionStyle() {
        let screen = makeScreen()
        // Equality holds at any ambient Theme.depth - both sides use the same depth.
        #expect(screen.highlightInput("@src/foo.swift") == Paint.mention("@src/foo.swift"))
        #expect(screen.highlightInput("hello") == Paint.fg(252, "hello"))
        // A multi-word line tints only the mention.
        #expect(screen.highlightInput("see @a.txt now")
            == Paint.fg(252, "see") + " " + Paint.mention("@a.txt") + " " + Paint.fg(252, "now"))
    }

    @Test("Paint.mention is bold + underlined when colored, and a no-op under NO_COLOR")
    func mentionStyling() {
        if Theme.depth == .none {
            #expect(Paint.mention("@x") == "@x")
        } else {
            let styled = Paint.mention("@x")
            #expect(styled.contains("\u{1B}[1;4;")) // bold (1) + underline (4) + color, merged
            #expect(styled.hasSuffix("\u{1B}[0m"))
            #expect(styled.contains("@x"))
        }
    }
}
