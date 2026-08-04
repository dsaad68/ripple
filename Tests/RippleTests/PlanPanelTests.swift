@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
@testable import ripple
import Testing

/// The pinned plan panel and the boxed-menu frame. The plan is shown once, pinned above the input box
/// and updated in place (no longer re-printed into the transcript), and every framed row keeps the
/// box aligned. Pure, model-free checks over `planPanelLines` / `drawPanel`.
@MainActor
struct PlanPanelTests {
    private func makeScreen() -> ChatScreen {
        let agent = RippleDeepAgent.make(textModel: FakeChatModel(answer: "x"))
        return ChatScreen(variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: ApprovalGate())
    }

    @Test func planPanelIsEmptyWithoutAPlan() {
        #expect(makeScreen().planPanelLines(width: 60).isEmpty)
    }

    /// A three-item plan frames to one box - top border (title + `1/3` count), three todo rows, bottom
    /// border - every row the same width, the in-progress item visible.
    @Test(arguments: [44, 60, 80])
    func planPanelFramesEveryRowAndShowsProgress(width: Int) {
        let screen = makeScreen()
        screen.plan = [
            TodoItem(content: "Inspect the directory", status: .completed),
            TodoItem(content: "Search the folder", status: .inProgress),
            TodoItem(content: "Summarize findings", status: .pending)
        ]
        let lines = screen.planPanelLines(width: width)
        #expect(lines.count == 5) // top + 3 todos + bottom
        let text = lines.map(\.text).joined(separator: "\n")
        #expect(text.contains("plan"))
        #expect(text.contains("1/3")) // one of three completed, on the top border
        #expect(text.contains("Search the folder"))
        for line in lines {
            #expect(TextWidth.of(line.text) == width + 2, "width \(width): <\(line.text)>")
        }
    }

    /// A long plan keeps the box compact: it windows around the active item and folds the rest into a
    /// `+N more` row rather than growing without bound.
    @Test func longPlanWindowsAndFoldsTheOverflow() {
        let screen = makeScreen()
        screen.plan = (1 ... 12).map { TodoItem(content: "step \($0)", status: $0 < 6 ? .completed : .pending) }
        let lines = screen.planPanelLines(width: 60)
        #expect(lines.count <= 8) // top + at most 6 body rows + bottom
        #expect(lines.map(\.text).joined().contains("more"))
    }

    /// Collapsed, the panel is just its titled bar (no body rows), so it never crowds the transcript.
    @Test func collapsedPlanPanelIsJustTheHeaderBar() {
        let screen = makeScreen()
        screen.plan = [TodoItem(content: "only step", status: .inProgress)]
        screen.planCollapsed = true
        let lines = screen.planPanelLines(width: 60)
        #expect(lines.count == 2) // top border (title) + bottom border
        guard case .togglePlan? = lines.first?.action else {
            Issue.record("expected the collapse toggle on the panel header")
            return
        }
    }

    /// The OpenRouter filter is a real bordered input box: three rows spanning the panel's inner
    /// width, the query and a cursor when typing, a placeholder (no cursor) when empty.
    @Test(arguments: [44, 60, 80])
    func openRouterFilterIsABorderedInputBox(width: Int) {
        let screen = makeScreen()
        screen.openRouterFilter = "llama"
        let typed = screen.filterFieldBox(width: width)
        #expect(typed.count == 3) // top border, field row, bottom border
        for line in typed { #expect(TextWidth.of(line.text) == width - 4) } // spans the panel's inner width
        #expect(typed[1].text.contains("llama"))
        #expect(typed[1].text.contains("▏")) // the cursor

        screen.openRouterFilter = ""
        let empty = screen.filterFieldBox(width: width)
        #expect(empty[1].text.contains("type to filter"))
        #expect(!empty[1].text.contains("▏")) // placeholder, no cursor
    }

    /// `drawPanel` frames a menu: the title rides the top border, the footer the bottom border, the
    /// body rows are boxed, and a clickable body row is registered in the click map.
    @Test func drawPanelFramesTitleFooterAndBody() {
        let screen = makeScreen()
        let body = [Line("alpha"), Line("beta", .togglePlan)]
        let frame = screen.drawPanel(width: 40, top: 2, height: 6,
                                     chrome: (title: Paint.fg(252, "Menu"), footer: Paint.fg(240, "esc close")),
                                     body: body)
        #expect(frame.contains("Menu"))
        #expect(frame.contains("esc close"))
        #expect(frame.contains("╭") && frame.contains("╰")) // rounded box corners
        #expect(frame.contains("alpha"))
        #expect(screen.clickMap.values.contains { if case .togglePlan = $0 { return true }; return false })
        // The box reserves three rows of chrome: the title border, a blank pad row under it, and the
        // bottom border - so the title never sits flush against the first item.
        #expect(screen.panelBodyHeight(6) == 3)
    }

    /// The selection band wraps a highlighted row in a background that survives the row's own color
    /// resets (so per-segment foregrounds keep their colors), and closes with a final reset.
    @Test func selectionBandWrapsTheRowInABackground() {
        let row = Paint.fg(252, "picked") // a styled row, with its own trailing reset
        let band = Paint.onBackground(row, Theme.userBg)
        if Theme.depth == .none {
            #expect(band == row) // no escapes to add under NO_COLOR
        } else {
            #expect(band != row)
            #expect(band.hasSuffix("\u{1B}[0m"))
        }
    }

    /// The footer hint colors key tokens (dim) apart from their descriptions (faint), so it reads as
    /// key → action pairs rather than one gray run.
    @Test func footerHintColorsKeysApartFromWords() {
        #expect(ChatScreen.footerHint("enter open")
            == Paint.fg(Theme.dim.xterm, "enter") + " " + Paint.fg(Theme.faint.xterm, "open"))
    }

    /// The pad row leaves the title with breathing room: with one body line in a 6-row box, the body
    /// region still shows it and the rest fills blank - the title is never flush against the content.
    @Test func titlePadReservesARowUnderTheTitle() {
        #expect(makeScreen().panelBodyHeight(10) == 7) // 10 - top border - title pad - bottom border
    }
}
