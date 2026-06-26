import DeepAgents
import Foundation

// The conversation transcript for `ripple chat`: user prompt boxes, the assistant's reasoning /
// answer runs, and the tree-style tool / subagent-task / plan steps. Split out of the render layer
// to keep that file within budget; the model types live in ChatScreenModel.
extension ChatScreen {
    // MARK: - Messages

    func messageLines(width: Int) -> [Line] {
        guard !messages.isEmpty else { return bannerLines(width: width) }
        var lines: [Line] = []
        for (index, message) in messages.enumerated() {
            // The last message while a turn runs is live (streaming assistant tokens or bang output),
            // so rebuild it every frame; every other message is final - reuse its cached rows at this
            // width, so a long session doesn't re-wrap the whole transcript on each redraw. The cache
            // is invalidated on resize (``sync``), clear / fresh, and any expand/collapse toggle.
            let live = index == messages.count - 1 && busy
            if !live, let cached = lineCache[index], cached.width == width {
                lines += cached.lines
            } else {
                let rendered = messageBlock(message, width: width)
                if !live { lineCache[index] = (width, rendered) }
                lines += rendered
            }
        }
        return lines
    }

    /// One message's rendered rows: a user prompt box, an assistant turn, or a bang command's output.
    private func messageBlock(_ message: Message, width: Int) -> [Line] {
        switch message.kind {
        case .user(let text): promptBox(text, width: width).map { Line($0) } + [Line("")]
        case .assistant(let assistant): assistantLines(assistant, width: width)
        case .bang(let bang): bangLines(bang, width: width)
        case .note(let text): noteLines(text, width: width)
        }
    }

    /// A dim system line (e.g. a context-compaction notice): a `↻` glyph then the wrapped text, set
    /// off by a trailing blank like the other blocks.
    private func noteLines(_ text: String, width: Int) -> [Line] {
        let wrapped = wrap(text, width - 4)
        guard !wrapped.isEmpty else { return [] }
        var out = wrapped.enumerated().map { index, line in
            Line("  " + Paint.fg(244, (index == 0 ? "↻ " : "  ") + line))
        }
        out.append(Line(""))
        return out
    }

    /// Drop the cached transcript rows - call after a non-append change (an expand/collapse toggle, a
    /// clear / fresh) so the next render rebuilds. Resize is handled in ``sync(render:)``.
    func invalidateTranscriptCache() { lineCache.removeAll() }

    private func promptBox(_ text: String, width: Int) -> [String] {
        let bg = 236
        let inner = width - 4
        let wrapped = wrap("❯ " + text, inner)
        var out = ["  " + Paint.bgFg(bg, 240, "╭" + String(repeating: "─", count: width - 2) + "╮")]
        for (index, lineText) in wrapped.enumerated() {
            let pad = String(repeating: " ", count: max(0, inner - TextWidth.of(lineText)))
            let body: String = index == 0 && lineText.hasPrefix("❯ ")
                ? Paint.bgArrow(bg) + Paint.bgFg(bg, 252, " " + String(lineText.dropFirst(2)))
                : Paint.bgFg(bg, 252, lineText)
            out.append("  " + Paint.bgEdge(bg, "│ ") + body + Paint.bgFg(bg, 245, pad) + Paint.bgEdge(bg, " │"))
        }
        out.append("  " + Paint.bgFg(bg, 240, "╰" + String(repeating: "─", count: width - 2) + "╯"))
        return out
    }

    private func assistantLines(_ a: Assistant, width: Int) -> [Line] {
        // Render the turn's blocks in the order the model produced them - reason → tool → reason →
        // answer - so a multi-round ReAct turn reads in sequence rather than grouped by type. Each
        // block is its own card (boxed tool call, boxed expanded thought, the answer run); a single
        // blank line between blocks keeps the boxes from touching.
        var groups: [[Line]] = []
        for block in a.blocks {
            switch block {
            case .reasoning(let reasoning): groups.append(reasoningLines(reasoning, width: width))
            case .step(let step): groups.append(stepLines(step, width: width))
            case .answer(let run): groups.append(answerLines(run.text, width: width))
            }
        }
        var out: [Line] = []
        for group in groups where !group.isEmpty {
            if !out.isEmpty { out.append(Line("")) }
            out += group
        }
        if a.interrupted { out.append(Line("  " + Paint.fg(174, "⊘ stopped"))) }
        out.append(Line(""))
        return out
    }

    /// How many output rows a finished bang command shows before collapsing the rest.
    static let bangPreviewLines = 5

    /// A bang command the user ran directly: a header (the `!!`/`!` sigil, the command, a dim target
    /// label, duration, status mark), then its output inside a box tinted to the target - green for
    /// the local shell, blue for the container. The box collapses to the first ``bangPreviewLines``
    /// rows once the command finishes; clicking the footer expands it.
    private func bangLines(_ bang: BangCommand, width: Int) -> [Line] {
        let local = bang.target == .local
        let accent = local ? 114 : 75 // green local shell, blue container
        let sigil = local ? "!!" : "!"
        let label = local ? "local shell" : "container"
        let phase: StepPhase = bang.running ? .running
            : (bang.failed || bang.interrupted || (bang.status ?? 0) != 0 ? .failed : .done)

        var head = "  " + Paint.fg(accent, sigil) + " " + Paint.fg(252, clip(bang.command, width - 26))
        head += "  " + Paint.fg(238, label)
        if let seconds = bang.seconds { head += Paint.fg(240, String(format: "  %.1fs", seconds)) }
        switch phase {
        case .done: head += "  " + Paint.fg(114, "✓")
        case .failed: head += "  " + Paint.fg(174, "✗")
        case .running: break
        }

        var out = [Line(head)]
        out += bangOutputBox(bang, accent: accent, phase: phase, width: width)
        if bang.interrupted { out.append(Line("     " + Paint.fg(174, "⊘ stopped"))) }
        out.append(Line(""))
        return out
    }

    /// The command's output inside a target-tinted box, collapsed to the first ``bangPreviewLines``
    /// rows once it finishes (a clickable footer toggles the rest). While it runs the full streamed
    /// tail is shown - the transcript follows the bottom - with a live `running…` line.
    private func bangOutputBox(_ bang: BangCommand, accent: Int, phase: StepPhase, width: Int) -> [Line] {
        let wrapped = wrap(bang.output, width - 4)
        guard !wrapped.isEmpty || bang.running else { return [] }
        let collapsible = !bang.running && wrapped.count > Self.bangPreviewLines
        let collapsed = collapsible && !bang.expanded
        let shown = collapsed ? Array(wrapped.prefix(Self.bangPreviewLines)) : wrapped
        let bodyColor = phase == .failed ? 174 : 244
        let inner = width - 4

        func boxRow(_ text: String, color: Int) -> Line {
            let pad = String(repeating: " ", count: max(0, inner - TextWidth.of(text)))
            return Line("  " + Paint.fg(accent, "│ ") + Paint.fg(color, text) + pad + Paint.fg(accent, " │"))
        }

        var out = [Line("  " + Paint.fg(accent, "╭" + String(repeating: "─", count: width - 2) + "╮"))]
        for line in shown { out.append(boxRow(line, color: bodyColor)) }
        if bang.running { out.append(boxRow("running…", color: 240)) }
        out.append(Line("  " + Paint.fg(accent, "╰" + String(repeating: "─", count: width - 2) + "╯")))

        if collapsed {
            let more = wrapped.count - Self.bangPreviewLines
            out.append(Line("     " + Paint.fg(240, "▸ \(more) more line\(more == 1 ? "" : "s")"), .toggleBang(bang)))
        } else if collapsible {
            out.append(Line("     " + Paint.fg(240, "▾ collapse"), .toggleBang(bang)))
        }
        return out
    }

    /// One reasoning block. While it streams it's a live `◆ thinking…` tail, and once collapsed a
    /// slim `◆ Thought for Xs ▸` line - both kept un-boxed on purpose: a border around a one-line
    /// summary is noise, and a box around the growing live tail would flicker its edge every frame.
    /// Only the *expanded* reasoning gets framed, so the revealed text reads as its own card.
    private func reasoningLines(_ reasoning: Reasoning, width: Int) -> [Line] {
        if reasoning.streaming {
            var out = [Line("  " + Paint.fg(141, "◆") + " " + Paint.fg(244, "thinking…"))]
            out += wrap(reasoning.text, width - 2).suffix(8).map { Line("    " + Paint.fg(240, $0)) }
            return out
        }
        let title = Paint.fg(141, "◆") + " "
            + Paint.fg(244, "Thought for \(String(format: "%.1f", reasoning.seconds ?? 0))s")
        guard reasoning.expanded else {
            return [Line("  " + title + " " + Paint.fg(240, "▸"), .toggleThought(reasoning))]
        }
        let rows = wrap(reasoning.text, width - 4).map { Line(Paint.fg(240, $0)) }
        return Self.card(width: width, title: title, trailing: Paint.fg(240, "▾"), rows: rows,
                         titleAction: .toggleThought(reasoning))
    }

    /// An answer run: the markdown-rendered text. Models often emit blank lines after `</think>`;
    /// trim them (and any the renderer adds) so the block is tight - ``assistantLines`` supplies the
    /// single blank-line gap between this and the block before it.
    private func answerLines(_ text: String, width: Int) -> [Line] {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return [] }
        var rendered = ChatMarkdown.render(answer, width: width - 2)
        while rendered.first?.isEmpty == true { rendered.removeFirst() }
        while rendered.last?.isEmpty == true { rendered.removeLast() }
        return rendered.map { Line("  " + $0) }
    }

    /// Whether a tool/task step is still running, finished, or failed - drives its status glyph.
    private enum StepPhase { case running, done, failed }

    private func stepLines(_ step: Step, width: Int) -> [Line] {
        guard case .tool(let name, _, _, let ok, let done, _) = step.kind else { return [] }
        let phase: StepPhase = !ok ? .failed : (done ? .done : .running)
        return name == "task"
            ? taskStepLines(step, phase: phase, width: width)
            : toolStepLines(step, phase: phase, width: width)
    }

    private func stepMark(_ phase: StepPhase) -> String {
        switch phase {
        case .running: Paint.fg(114, "▏")
        case .done: Paint.fg(114, "✓")
        case .failed: Paint.fg(174, "✗")
        }
    }

    /// A card's right-border trailing segment: the wall-clock duration (once the call finishes) and a
    /// ▸/▾ disclosure marker (when the card can expand), joined to ride the top border's right end.
    private func cardTrailing(_ step: Step, disclosure: String?) -> String {
        var parts: [String] = []
        if let seconds = step.seconds { parts.append(Paint.fg(240, String(format: "%.1fs", seconds))) }
        if let disclosure { parts.append(Paint.fg(240, disclosure)) }
        return parts.joined(separator: " ")
    }

    /// A plain tool call, framed as a light card: the gear + tool name ride the top border (with the
    /// duration / ▸-▾ disclosure on the right), the args are the first body row, and the result is one
    /// clipped row by default, or the full wrapped output when the step is expanded (click the header
    /// to toggle). A failed call gets a louder red frame.
    private func toolStepLines(_ step: Step, phase: StepPhase, width: Int) -> [Line] {
        guard case .tool(let name, let detail, let output, _, _, _) = step.kind else { return [] }
        if phase == .failed, let reason = ShellBlock.reason(in: output) {
            return shellBlockedLines(name: name, detail: detail, reason: reason, step: step, width: width)
        }
        if let diff = step.diff, phase != .failed {
            return editStepLines(step, name: name, diff: diff, width: width)
        }
        let inner = width - 4 // visible columns inside the box
        let expandable = output.contains("\n") || TextWidth.of(output) > inner - 2
        let title = Paint.fg(179, "⚙") + " " + Paint.fg(252, clip(name, max(8, inner - 12)))
        let trailing = cardTrailing(step, disclosure: expandable ? (step.expanded ? "▾" : "▸") : nil)
        var rows: [Line] = []
        if !detail.isEmpty { rows.append(Line(Paint.fg(244, clip(detail, inner)))) }
        if !output.isEmpty {
            let mark = stepMark(phase)
            if step.expanded {
                for (index, line) in wrap(output, inner - 2).enumerated() {
                    rows.append(Line((index == 0 ? mark : " ") + " " + colorizeOutput(line, phase: phase)))
                }
            } else {
                rows.append(Line(mark + " " + colorizeOutput(clip(output, inner - 2), phase: phase)))
            }
        }
        return Self.card(width: width, title: title, trailing: trailing, rows: rows,
                         edge: phase == .failed ? Theme.danger.xterm : Theme.border.xterm,
                         titleAction: expandable ? .toggleStep(step) : nil)
    }

    /// The collapsed diff card shows at most this many rows; beyond it the card folds behind a
    /// "… N more" line that the ▸/▾ disclosure expands.
    private static let diffCollapsedCap = 12

    /// An `edit_file` step rendered as a diff card: the gear/name on the top border, a `Update <path>`
    /// row and a `+added -removed` summary, then the changed lines (red `-` / green `+`) with a faint
    /// line-number gutter and a few lines of context. Long diffs collapse to ``diffCollapsedCap`` rows
    /// behind the ▸/▾ disclosure (click the header to toggle, same as any tool card).
    private func editStepLines(_ step: Step, name: String, diff: FileDiff, width: Int) -> [Line] {
        let inner = width - 4
        let title = Paint.fg(179, "⚙") + " " + Paint.fg(252, clip(name, max(8, inner - 12)))
        var rows: [Line] = [
            Line(Paint.fg(244, "Update ") + Paint.fg(252, clip(diff.path, max(8, inner - 7)))),
            Line(Paint.fg(114, "+\(diff.added)") + "  " + Paint.fg(174, "-\(diff.removed)"))
        ]
        let body = editDiffRows(diff, inner: inner)
        let expandable = body.count > Self.diffCollapsedCap
        if step.expanded || !expandable {
            rows.append(contentsOf: body.map { Line($0) })
        } else {
            rows.append(contentsOf: body.prefix(Self.diffCollapsedCap).map { Line($0) })
            rows.append(Line(Paint.fg(238, "  … \(body.count - Self.diffCollapsedCap) more")))
        }
        let trailing = cardTrailing(step, disclosure: expandable ? (step.expanded ? "▾" : "▸") : nil)
        return Self.card(width: width, title: title, trailing: trailing, rows: rows,
                         edge: Theme.border.xterm, titleAction: expandable ? .toggleStep(step) : nil)
    }

    /// The diff body as inner box-content rows: each hunk's lines (a faint right-aligned line-number
    /// gutter, then `+`/`-`/context text in green/red/grey), with a faint `⋯` gap between hunks.
    private func editDiffRows(_ diff: FileDiff, inner: Int) -> [String] {
        func gutter(_ number: Int?) -> String {
            let text = number.map(String.init) ?? ""
            return Paint.fg(240, String(repeating: " ", count: max(0, 4 - text.count)) + text)
        }
        func row(_ line: FileDiff.Line) -> String {
            let body = clip(line.text, max(8, inner - 8))
            switch line.kind {
            case .added: return gutter(line.newNumber) + " " + Paint.fg(114, "+ " + body)
            case .removed: return gutter(line.oldNumber) + " " + Paint.fg(174, "- " + body)
            case .context: return gutter(line.newNumber) + " " + Paint.fg(244, "  " + body)
            }
        }
        var rows: [String] = []
        for (index, hunk) in diff.hunks.enumerated() {
            if index > 0 { rows.append(Paint.fg(238, "  ⋯")) }
            rows.append(contentsOf: hunk.map(row))
        }
        return rows
    }

    /// A shell command the safety policy refused, framed in a red card: the gear/name on the top
    /// border, the command as an arg row, then a loud `BLOCKED` badge with the bare reason - distinct
    /// from an ordinary failed call, and never showing the raw `{"error":…}` payload.
    private func shellBlockedLines(name: String, detail: String, reason: String, step: Step, width: Int) -> [Line] {
        let inner = width - 4
        let title = Paint.fg(179, "⚙") + " " + Paint.fg(252, clip(name, max(8, inner - 12)))
        var rows: [Line] = []
        if !detail.isEmpty { rows.append(Line(Paint.fg(244, clip(detail, inner)))) }
        let badge = Paint.bgFg(Theme.danger.xterm, 232, " BLOCKED ")
        rows.append(Line(badge + " " + Paint.fg(Theme.danger.xterm, clip(reason, max(8, inner - 10)))))
        return Self.card(width: width, title: title, trailing: cardTrailing(step, disclosure: nil),
                         rows: rows, edge: Theme.danger.xterm)
    }

    /// Color a tool result: a JSON-ish payload gets keys / strings / numbers / punctuation tinted;
    /// an error stays red; anything else is plain muted text.
    private func colorizeOutput(_ text: String, phase: StepPhase) -> String {
        if phase == .failed { return Paint.fg(174, text) }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return Paint.fg(244, text) }
        let chars = Array(text)
        var out = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                var token = "\""
                index += 1
                while index < chars.count {
                    token.append(chars[index])
                    let closed = chars[index] == "\"" && chars[index - 1] != "\\"
                    index += 1
                    if closed { break }
                }
                var ahead = index
                while ahead < chars.count, chars[ahead] == " " { ahead += 1 }
                let isKey = ahead < chars.count && chars[ahead] == ":"
                out += Paint.fg(isKey ? 75 : 114, token) // keys blue, value strings green
            } else if "{}[],:".contains(char) {
                out += Paint.fg(240, String(char))
                index += 1
            } else if char.isNumber || char == "-" {
                var number = ""
                while index < chars.count, chars[index].isNumber || chars[index] == "." || chars[index] == "-" {
                    number.append(chars[index]); index += 1
                }
                out += Paint.fg(215, number)
            } else {
                out += Paint.fg(244, String(char))
                index += 1
            }
        }
        return out
    }

    /// A subagent delegation (`task`): the subagent's reasoning and its result are each collapsible
    /// and collapsed by default, so a delegate stays compact and never floods the transcript with a
    /// wall of subagent output. While it streams we show a live `◆ thinking…` tail; once done the
    /// reasoning folds into `◆ Thought for Xs ▸` and the result hides behind the `◈` header's ▾/▸ -
    /// click either to reveal it.
    private func taskStepLines(_ step: Step, phase: StepPhase, width: Int) -> [Line] {
        guard case .tool(_, let ask, let output, _, _, let subagent) = step.kind else { return [] }
        let who = subagent ?? "subagent"
        let status: String = switch phase {
        case .running: Paint.fg(179, "▍")
        case .done: Paint.fg(114, "✓")
        case .failed: Paint.fg(174, "✗")
        }
        let (reasoning, answer) = Self.splitThink(output)
        let hasResult = !answer.isEmpty
        let inner = width - 4

        let title = Paint.fg(141, "◈") + " " + Paint.fg(252, "delegate ") + Paint.fg(244, "→ \(who) ") + status
        let trailing = cardTrailing(step, disclosure: hasResult ? (step.expanded ? "▾" : "▸") : nil)
        var rows: [Line] = []
        let request = clip(taskAsk(ask), inner)
        if !request.isEmpty { rows.append(Line(Paint.fg(240, request))) }

        // Subagent reasoning: a live tail while it thinks, else a collapsed `◆ Thought for Xs ▸`.
        if !reasoning.isEmpty {
            if phase == .running, answer.isEmpty {
                rows.append(Line(Paint.fg(141, "◆") + " " + Paint.fg(244, "thinking…")))
                rows += wrap(reasoning, inner - 2).suffix(4).map { Line("  " + Paint.fg(240, $0)) }
            } else {
                let secs = step.seconds.map { " for \(String(format: "%.1f", $0))s" } ?? ""
                rows.append(Line(
                    Paint.fg(141, "◆") + " " + Paint.fg(244, "Thought\(secs)")
                        + " " + Paint.fg(240, step.thinkExpanded ? "▾" : "▸"),
                    .toggleStepThought(step)
                ))
                if step.thinkExpanded {
                    rows += wrap(reasoning, inner - 2).map { Line("  " + Paint.fg(240, $0)) }
                }
            }
        }

        // Subagent result: shown under the ◈ header by default, hidden when the user collapses it.
        if hasResult, step.expanded {
            rows += wrap(answer, inner - 2).map {
                Line(Paint.fg(238, "┊ ") + Paint.fg(phase == .done ? 245 : 250, $0))
            }
        }
        return Self.card(width: width, title: title, trailing: trailing, rows: rows,
                         edge: phase == .failed ? Theme.danger.xterm : Theme.border.xterm,
                         titleAction: hasResult ? .toggleStep(step) : nil)
    }

    /// Split a subagent's streamed output into its `<think>…</think>` reasoning and the rest (its
    /// answer). Handles streaming (an unclosed `<think>` = all reasoning, no answer yet) and the
    /// no-reasoning case (no tag = all answer).
    static func splitThink(_ output: String) -> (reasoning: String, answer: String) {
        guard let open = output.range(of: "<think>") else {
            return ("", output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let afterOpen = output[open.upperBound...]
        guard let close = afterOpen.range(of: "</think>") else {
            return (afterOpen.trimmingCharacters(in: .whitespacesAndNewlines), "") // still thinking
        }
        let reasoning = String(afterOpen[..<close.lowerBound])
        let answer = String(output[..<open.lowerBound]) + String(afterOpen[close.upperBound...])
        return (
            reasoning.trimmingCharacters(in: .whitespacesAndNewlines),
            answer.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// The pinned plan panel drawn just above the input box: one light card titled `plan`, an `N/M`
    /// completed count on the right border, and a row per todo (○ pending, ▸ in progress, ✔ done).
    /// Empty when there's no plan. A long plan keeps the in-progress item in view and folds the
    /// overflow into a `+N more` row so the panel never crowds out the transcript; collapsed
    /// (click the header), it's just the titled bar.
    func planPanelLines(width: Int) -> [Line] {
        guard !plan.isEmpty else { return [] }
        let done = plan.filter { $0.status == .completed }.count
        let title = Paint.fg(141, "◇") + " " + Paint.fg(252, "plan")
        let trailing = Paint.fg(240, "\(done)/\(plan.count)") + " " + Paint.fg(240, planCollapsed ? "▸" : "▾")
        guard !planCollapsed else {
            return Self.card(width: width, title: title, trailing: trailing, rows: [], titleAction: .togglePlan)
        }
        let inner = width - 4
        func row(_ todo: TodoItem) -> Line {
            let glyph: String
            let color: Int
            switch todo.status {
            case .completed: glyph = Paint.fg(114, "✔"); color = 240
            case .inProgress: glyph = Paint.fg(179, "▸"); color = 252
            case .pending: glyph = Paint.fg(240, "○"); color = 244
            }
            return Line(glyph + " " + Paint.fg(color, clip(todo.content, inner - 2)))
        }
        let cap = 6
        var rows: [Line]
        if plan.count <= cap {
            rows = plan.map(row)
        } else {
            // Window the list around the active item so a long plan stays compact yet shows progress.
            let focus = plan.firstIndex { $0.status == .inProgress }
                ?? plan.firstIndex { $0.status == .pending } ?? 0
            let visible = cap - 1
            let start = max(0, min(focus - visible / 2, plan.count - visible))
            rows = plan[start ..< start + visible].map(row)
            rows.append(Line("  " + Paint.fg(240, "+\(plan.count - visible) more")))
        }
        return Self.card(width: width, title: title, trailing: trailing, rows: rows, titleAction: .togglePlan)
    }

    /// The `description` argument of a `task` call (the request to the subagent). Keys are alphabetical,
    /// so the description runs up to the next key (`subagent_type`) even when it contains commas.
    private func taskAsk(_ detail: String) -> String {
        guard let start = detail.range(of: "description: ") else { return detail }
        let rest = detail[start.upperBound...]
        if let end = rest.range(of: ", subagent_type: ") { return String(rest[..<end.lowerBound]) }
        return String(rest)
    }
}
