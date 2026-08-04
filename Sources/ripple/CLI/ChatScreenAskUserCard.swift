import DeepAgents
import Foundation

// The `ask_user` card for `ripple chat`: a bordered box (reusing ``ChatScreen/approvalBox``) with a
// tab strip across the questions, the active question, and either its choices (plus an "Other"
// free-text row) or a hint that a text answer goes in the input box below. The state machine that
// drives it lives in ChatScreenAskUser; the model types in ChatScreenModel.
extension ChatScreen {
    /// The card the agent's `ask_user` call shows above the status line. It owns the bottom region
    /// while a prompt is up (replacing the normal input box), so the answer is typed on a line *inside*
    /// the card's border rather than in a separate box below it. `askUserCursorCell` records where the
    /// caret lands, set here and read by `render()`.
    func askUserLines(_ request: AskUserRequest, width: Int) -> [Line] {
        askUserCursorCell = nil
        let inner = width - 4 // visible columns between "│ " and " │"
        let questions = request.questions
        var rows: [(String, ClickAction?)] = []

        rows.append((askUserTabStrip(questions), nil))
        rows.append(("", nil)) // a spacer between the tabs and the question

        guard let question = askUserQuestion else {
            return Self.approvalBox(width: width, title: Paint.fg(252, "Ask user"), rows: rows)
        }

        // The question text, wrapped to the box width. An "(optional)" tag rides the last line when it
        // fits, else drops to its own line - so neither the text nor the tag spills past the border.
        let questionLines = wrap(question.question, inner)
        let tag = "   (optional)"
        let tagFitsLast = !question.required
            && (questionLines.last.map { TextWidth.of($0) + TextWidth.of(tag) <= inner } ?? false)
        for (index, line) in questionLines.enumerated() {
            let withTag = tagFitsLast && index == questionLines.count - 1
            rows.append((Paint.fg(252, line) + (withTag ? Paint.fg(240, tag) : ""), nil))
        }
        if !question.required, !tagFitsLast { rows.append((Paint.fg(240, "(optional)"), nil)) }
        rows.append(("", nil))

        if question.type != .text {
            let multi = question.type == .multiSelect
            let valueWidth = inner - (multi ? 12 : 8) // room for the marker, checkbox, and number shortcut
            for (index, choice) in question.choices.enumerated() {
                let on = !askUserEditing && askUserChoice == index
                let box = multi ? (askUserChecked(index) ? "[x] " : "[ ] ") : ""
                rows.append((askUserChoiceRow(box + clip(choice.value, valueWidth), on: on, key: index + 1),
                             .selectAskUserChoice(index)))
            }
            rows.append((askUserOtherRow(question, inner: inner), .selectAskUserChoice(question.choices.count)))
        }

        // The answer field, embedded inside the card's border (only while a free-text answer is being
        // typed - a text question, or the "Other" option). The caret cell is recorded for `render()`.
        if askUserEditing {
            if question.type != .text { rows.append(("", nil)) } // a gap under the choices
            appendAskUserAnswerRows(into: &rows, inner: inner)
        }

        rows.append(("", nil))
        rows.append((Paint.fg(240, clip(askUserFooter(), inner)), .submitAskUser)) // clip so a narrow box never spills

        let title = Paint.fg(141, "◆") + " " + Paint.fg(252, "Ask user")
            + Paint.fg(244, "  \(askUserTab + 1)/\(questions.count)")
        return Self.approvalBox(width: width, title: title, rows: rows)
    }

    /// Append the live answer (the input buffer) as one or more rows inside the card, behind a `❯`
    /// prompt, windowed to a few lines and laid out with the same wrap/caret logic as the main input
    /// box. Records `askUserCursorCell` as a card-relative row plus an absolute screen column.
    private func appendAskUserAnswerRows(into rows: inout [(String, ClickAction?)], inner: Int) {
        let answerWidth = max(4, inner - 2) // room after the "❯ " prompt
        let layout = layoutInput(input, width: answerWidth, cursor: cursor)
        let maxRows = 4
        var windowStart = max(0, layout.rows.count - maxRows)
        if layout.line < windowStart { windowStart = layout.line }
        if layout.line >= windowStart + maxRows { windowStart = layout.line - maxRows + 1 }
        let visible = Array(layout.rows[windowStart ..< min(layout.rows.count, windowStart + maxRows)])

        let firstCardRow = rows.count + 1 // +1 for the box top border approvalBox prepends
        for (offset, text) in visible.enumerated() {
            let prompt = offset == 0 ? Paint.arrow("❯") + " " : "  "
            let shown = (offset == 0 && input.isEmpty) ? Paint.fg(240, "type your answer…") : Paint.fg(252, text)
            rows.append((prompt + shown, nil))
        }
        // Caret column matches the main input box's geometry (content at col 5, "❯ " prompt, text at 7).
        askUserCursorCell = (row: firstCardRow + (layout.line - windowStart), col: 7 + layout.col)
    }

    /// The tab strip: one chip per question, the active one inverted, answered ones tinted green. Each
    /// chip is clickable to jump to that question.
    private func askUserTabStrip(_ questions: [AskUserQuestion]) -> String {
        questions.indices.map { index in
            let answered = index < askUserAnswers.count && !askUserAnswers[index].isEmpty
            let label = " Q\(index + 1) "
            if index == askUserTab { return Paint.bgFg(238, 252, label) }
            return Paint.fg(answered ? 114 : 244, label)
        }.joined(separator: " ")
    }

    /// One choice row: a ❯ marker when selected, the label tinted (bright when selected), and its
    /// number shortcut aligned to the right.
    private func askUserChoiceRow(_ label: String, on selected: Bool, key: Int) -> String {
        let marker = selected ? Paint.arrow("❯") + " " : "  "
        let shortcut = key <= 9 ? Paint.fg(238, "  (\(key))") : ""
        return marker + Paint.fg(selected ? 252 : 244, label) + shortcut
    }

    /// The trailing "Other" row: the "type below" cue while editing it, the typed custom value (a
    /// multi-select keeps it alongside the checked options), or a plain "Other…".
    private func askUserOtherRow(_ question: AskUserQuestion, inner: Int) -> String {
        let otherIndex = question.choices.count
        let on = askUserChoice == otherIndex
        let other = (askUserMultiSelect && askUserOther.indices.contains(askUserTab)) ? askUserOther[askUserTab] : ""
        let label: String
        if askUserEditing, on {
            label = "Other (type below)"
        } else if askUserMultiSelect, !other.isEmpty {
            label = "Other: " + clip(other, inner - 16)
        } else {
            label = "Other…"
        }
        return askUserChoiceRow(label, on: on, key: otherIndex + 1)
    }

    /// The footer hint, which depends on the question kind, whether a free-text answer is being typed,
    /// and how many questions there are. Esc backs out of an "Other" entry but cancels elsewhere.
    private func askUserFooter() -> String {
        let switchHint = (askGate.pending?.questions.count ?? 0) > 1 ? " · ↹ switch question" : ""
        if askUserEditing {
            let esc = askUserQuestion?.type == .text ? "esc cancel" : "esc back"
            return "enter submit answer\(switchHint) · \(esc)"
        }
        if askUserMultiSelect {
            return "↑↓ move · space toggle · enter next/submit\(switchHint) · esc cancel"
        }
        return "↑↓ choose · enter next/submit\(switchHint) · esc cancel"
    }
}
