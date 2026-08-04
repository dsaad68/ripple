import DeepAgents
import Foundation

// The `ask_user` form for `ripple chat`: the tabbed-card state machine (one tab per question; a
// single-choice list, a multi-select checkbox list, or a free-text box, each with an always-available
// "Other" escape) and the keys that drive it. The card is rendered in ChatScreenAskUserCard; the
// suspend/resume bridge is ``AskUserGate``. Modeled on the approval flow in ChatScreenTurn.
extension ChatScreen {
    // MARK: - Derived state

    /// The question on the active tab, or nil when nothing is pending.
    var askUserQuestion: AskUserQuestion? {
        guard let pending = askGate.pending, pending.questions.indices.contains(askUserTab) else { return nil }
        return pending.questions[askUserTab]
    }

    /// Whether the active question presents choices (single- or multi-select), vs. a free-text question.
    var askUserHasChoices: Bool { askUserQuestion.map { $0.type != .text } ?? false }

    /// Whether the active question is multi-select (checkboxes; one or more answers).
    var askUserMultiSelect: Bool { askUserQuestion?.type == .multiSelect }

    /// Selectable rows for the active choice question: its choices plus a trailing "Other" (free-text)
    /// row. Zero for a text question, where the input box is the answer.
    var askUserChoiceCount: Int {
        guard let question = askUserQuestion, question.type != .text else { return 0 }
        return question.choices.count + 1 // +1 for the "Other" row
    }

    /// Whether the active choice selection is the trailing "Other" (free-text) row.
    var askUserOnOther: Bool {
        guard let question = askUserQuestion, question.type != .text else { return false }
        return askUserChoice == question.choices.count
    }

    /// Whether choice `index` is checked in the active multi-select question.
    func askUserChecked(_ index: Int) -> Bool {
        askUserSelected.indices.contains(askUserTab) && askUserSelected[askUserTab].contains(index)
    }

    // MARK: - Seeding

    /// Re-initialize the form when a fresh ask_user request arrives - keyed on its id, so the redraws
    /// ``AskUserGate/onChange`` fires never clobber in-progress answers. Mirrors `seedApprovalSelection`.
    func seedAskUserState() {
        guard let pending = askGate.pending else { lastAskUserID = nil; return }
        guard pending.id != lastAskUserID else { return }
        lastAskUserID = pending.id
        askUserTab = 0
        askUserAnswers = Array(repeating: "", count: pending.questions.count)
        askUserSelected = pending.questions.map { _ in Set<Int>() }
        askUserOther = Array(repeating: "", count: pending.questions.count)
        focusAskUserTab()
    }

    /// Focus the active tab: a text question opens the input box; a single-choice question keeps the
    /// highlighted choice as the live answer; a multi-select question shows checkboxes (its answer is
    /// derived from the checked set when the tab is committed).
    func focusAskUserTab() {
        guard let question = askUserQuestion, askUserAnswers.indices.contains(askUserTab) else { return }
        askUserChoice = 0
        switch question.type {
        case .text:
            askUserEditing = true
            setInput(askUserAnswers[askUserTab])
        case .multipleChoice:
            askUserEditing = false
            clearInput()
            askUserAnswers[askUserTab] = question.choices.first?.value ?? ""
        case .multiSelect:
            askUserEditing = false
            clearInput()
        }
    }

    // MARK: - Navigation

    /// Move the highlight in the active choice question (↑/↓); for a single-choice question that also
    /// makes the highlighted option the live answer.
    func moveAskUserChoice(_ delta: Int) {
        guard !askUserEditing, askUserChoiceCount > 0 else { return }
        askUserChoice = (askUserChoice + delta + askUserChoiceCount) % askUserChoiceCount
        syncHighlightedChoice()
    }

    /// Jump to a choice row (number keys / click): a multi-select row toggles, a single-choice row
    /// becomes the answer; "Other" just highlights (the caller starts free-text entry).
    func selectAskUserChoice(_ index: Int) {
        guard index >= 0, index < askUserChoiceCount else { return }
        askUserChoice = index
        if askUserOnOther { return }
        if askUserMultiSelect { toggleAskUserChoice() } else { syncHighlightedChoice() }
    }

    /// Toggle the highlighted choice in a multi-select question (Space / number / click).
    func toggleAskUserChoice() {
        guard askUserMultiSelect, !askUserOnOther, askUserSelected.indices.contains(askUserTab) else { return }
        if askUserSelected[askUserTab].contains(askUserChoice) {
            askUserSelected[askUserTab].remove(askUserChoice)
        } else {
            askUserSelected[askUserTab].insert(askUserChoice)
        }
    }

    private func syncHighlightedChoice() {
        guard askUserQuestion?.type == .multipleChoice, !askUserOnOther,
              let question = askUserQuestion, askUserAnswers.indices.contains(askUserTab) else { return }
        askUserAnswers[askUserTab] = question.choices[askUserChoice].value
    }

    /// Switch to another question tab (Tab / Shift-Tab), saving the in-progress answer first.
    func moveAskUserTab(_ delta: Int) {
        guard let pending = askGate.pending, !pending.questions.isEmpty else { return }
        commitAskUserEditing()
        finalizeAskUserAnswer()
        askUserTab = (askUserTab + delta + pending.questions.count) % pending.questions.count
        focusAskUserTab()
    }

    // MARK: - Commit / submit

    /// Enter on the card: on the "Other" row start free-text entry; otherwise commit the current answer
    /// and advance to the next question, or submit on the last one.
    func askUserAdvanceOrSubmit() {
        guard let pending = askGate.pending else { return }
        if askUserOnOther, !askUserEditing { beginAskUserOther(); return }
        commitAskUserEditing()
        finalizeAskUserAnswer()
        if askUserTab >= pending.questions.count - 1 {
            resolveAskUser(.answered(askUserAnswers))
        } else {
            askUserTab += 1
            focusAskUserTab()
        }
    }

    /// Begin typing a custom "Other" value for the active choice question (re-loading any prior value
    /// for a multi-select, where the "Other" text is kept alongside the checked options).
    func beginAskUserOther() {
        guard let question = askUserQuestion else { return }
        askUserChoice = question.choices.count // the "Other" row
        askUserEditing = true
        setInput(askUserMultiSelect && askUserOther.indices.contains(askUserTab) ? askUserOther[askUserTab] : "")
    }

    /// Save the input box while a free-text entry is open: a multi-select "Other" value is kept aside
    /// (merged into the answer on finalize); for text / single-choice it *is* the answer.
    private func commitAskUserEditing() {
        guard askUserEditing else { return }
        if askUserMultiSelect {
            if askUserOther.indices.contains(askUserTab) { askUserOther[askUserTab] = inputText }
        } else if askUserAnswers.indices.contains(askUserTab) {
            askUserAnswers[askUserTab] = inputText
        }
    }

    /// Derive a multi-select question's answer from its checked choices plus any "Other" text, joined
    /// by ", ". A no-op for the other kinds (whose answer is already current).
    private func finalizeAskUserAnswer() {
        guard askUserMultiSelect, let question = askUserQuestion,
              askUserAnswers.indices.contains(askUserTab), askUserSelected.indices.contains(askUserTab) else { return }
        var values = askUserSelected[askUserTab].sorted().compactMap { index in
            question.choices.indices.contains(index) ? question.choices[index].value : nil
        }
        let other = (askUserOther.indices.contains(askUserTab) ? askUserOther[askUserTab] : "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !other.isEmpty { values.append(other) }
        askUserAnswers[askUserTab] = values.joined(separator: ", ")
    }

    func resolveAskUser(_ response: AskUserResponse) {
        askUserEditing = false
        clearInput()
        askGate.resolve(response)
    }

    /// Esc on the card: back out of an open "Other" free-text entry to the choice list; otherwise
    /// cancel the whole prompt (the agent receives a cancelled answer per question).
    func escapeAskUser() {
        if askUserEditing, askUserHasChoices {
            askUserEditing = false
            clearInput()
        } else {
            resolveAskUser(.cancelled)
        }
    }

    // MARK: - Keys

    /// Keys while the card is up and NOT in free-text mode (free text falls through to the input box):
    /// Space toggles a multi-select choice, digits pick a choice, Enter advances/submits, Tab switches
    /// questions, arrows move (as CSI), Ctrl-C stops the turn.
    func handleAskUserByte(_ byte: UInt8) {
        switch byte {
        case 0x1B: pendingEsc = true // arrow keys arrive as CSI sequences; let the parser collect them
        case 0x0D, 0x0A: askUserAdvanceOrSubmit()
        case 0x20: toggleAskUserChoice() // Space toggles a multi-select choice
        case 0x09: moveAskUserTab(1) // Tab -> next question
        case 0x03: cancelTurn() // Ctrl-C stops the whole turn
        case 0x04: quit = true // Ctrl-D
        case 0x31 ... 0x39: selectAskUserChoice(Int(byte - 0x31)) // 1-9 pick a choice row
        default: break
        }
    }
}
