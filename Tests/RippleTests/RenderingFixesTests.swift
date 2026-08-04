@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
@testable import ripple
import Testing

/// The rendering / scrolling / input-robustness fixes: ESC-sequence disambiguation that doesn't drop
/// split sequences, a scroll clamp that uses the boxed-menu viewport, and a transcript line cache that
/// only rebuilds the live message. Pure, model-free checks (no tty needed - the input batching's
/// classification is extracted so it can be unit-tested).
@MainActor
struct RenderingFixesTests {
    private func makeScreen() -> ChatScreen {
        let agent = RippleDeepAgent.make(textModel: FakeChatModel(answer: "x"))
        return ChatScreen(variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: ApprovalGate())
    }

    /// A trailing `ESC` is the only ambiguous byte: ESC followed by more bytes in the same batch is a
    /// sequence start (never a lone Escape), so a split-across-reads sequence isn't dropped as Escape.
    @Test func classifyOnlyDisambiguatesATrailingEscape() {
        #expect(Terminal.classify([0x1B, 0x5B, 0x41]) { false } == [.byte(0x1B), .byte(0x5B), .byte(0x41)])
        #expect(Terminal.classify([0x1B]) { false } == [.escape]) // trailing ESC, nothing follows -> Escape
        #expect(Terminal.classify([0x1B]) { true } == [.byte(0x1B)]) // trailing ESC, more waiting -> sequence
        #expect(Terminal.classify([0x41, 0x1B]) { true } == [.byte(0x41), .byte(0x1B)]) // non-ESC byte is itself
    }

    /// The scroll viewport is the full content height for the transcript, but shorter inside a boxed
    /// menu (it loses the box's top + bottom borders and the title pad row).
    @Test func scrollViewportShrinksInBoxedMenus() {
        let screen = makeScreen()
        screen.contentHeight = 20
        #expect(screen.scrollViewport == 20) // transcript: the whole content area
        screen.help = true // a boxed menu owns the screen
        #expect(screen.scrollViewport == screen.panelBodyHeight(20)) // minus borders + title pad
    }

    /// `scroll(by:)` clamps to the active viewport, so a boxed detail pane can scroll all the way to
    /// its last row instead of stopping a few rows short.
    @Test func scrollReachesTheLastRowInABoxedMenu() {
        let screen = makeScreen()
        screen.contentHeight = 10
        screen.totalLines = 30
        screen.help = true
        screen.scroll(by: 1000) // scroll to the very bottom
        #expect(screen.scrollOffset == 30 - screen.panelBodyHeight(10)) // 30 - 7 = 23
        #expect(screen.scrollOffset > 30 - 10) // reaches further than the old contentHeight clamp (20)
    }

    /// Final messages are cached at their width; the cache is dropped on demand (a toggle / clear).
    @Test func transcriptCachesFinalMessagesAndInvalidates() {
        let screen = makeScreen()
        screen.messages.append(Message(kind: .user("hello there")))
        screen.contentHeight = 20
        _ = screen.messageLines(width: 60)
        #expect(screen.lineCache[0]?.width == 60)
        screen.invalidateTranscriptCache()
        #expect(screen.lineCache.isEmpty)
    }

    /// The live (last, while a turn runs) message is rebuilt every frame, not cached - so streaming
    /// output keeps updating; the earlier, final messages are cached.
    @Test func liveMessageIsNotCached() {
        let screen = makeScreen()
        screen.messages.append(Message(kind: .user("a")))
        screen.messages.append(Message(kind: .user("b")))
        screen.running = true // busy -> the last message is treated as live
        screen.contentHeight = 20
        _ = screen.messageLines(width: 60)
        #expect(screen.lineCache[0] != nil) // the earlier message is cached
        #expect(screen.lineCache[1] == nil) // the live (last) message is not
    }
}
