import DeepAgents
import Foundation

// Editing the bottom input box for `ripple chat`: text insertion/deletion, cursor and word motion,
// prompt history, viewport scroll position, and the `@file` mention completion. Split out of
// ChatScreen to keep that file within budget; the model types live in ChatScreenModel.
extension ChatScreen {
    // MARK: - Editing

    // The input stays editable while a turn runs (compose the next message); `submit` blocks the send.
    // A pending approval takes over the keyboard, so editing is off until the user decides.
    var editable: Bool {
        // The `/model` overlay only accepts typed input in the Select tab's idle-minutes field; the
        // `/config` editor only in its container-image field. Otherwise their row keys own the keyboard.
        if modelHub != nil { return modelEditingIdle }
        if config != nil { return configEditingImage }
        return toolsBrowser == nil && !help && downloading == nil
            && (gate.pending == nil || editingApproval != nil)
            && (askGate.pending == nil || askUserEditing) // the ask_user card owns the keys unless typing an answer
    }

    func insert(_ byte: UInt8) {
        guard editable else { return }
        pendingBytes.append(byte)
        guard let decoded = String(bytes: pendingBytes, encoding: .utf8) else { return } // incomplete UTF-8
        for char in decoded { input.insert(char, at: cursor); cursor += 1 }
        pendingBytes.removeAll()
        historyIndex = nil
        menuIndex = 0
    }

    /// Insert a hard line break (Shift-Enter / Alt-Enter, or a newline inside a paste). Plain Enter
    /// still sends.
    func insertNewline() {
        guard editable else { return }
        input.insert("\n", at: cursor)
        cursor += 1
        historyIndex = nil
        menuIndex = 0
    }

    /// One byte of a bracketed-paste body: newlines become hard breaks, other control bytes are
    /// dropped, and the rest flows through the normal UTF-8 insert.
    func insertPasted(_ byte: UInt8) {
        switch byte {
        case 0x0A: insertNewline()
        case 0x09: insert(0x20) // tab -> space
        case 0x00 ..< 0x20, 0x7F: break // drop CR and other control bytes
        default: insert(byte)
        }
    }

    func deleteBackward() {
        guard editable, cursor > 0 else { return }
        input.remove(at: cursor - 1)
        cursor -= 1
        historyIndex = nil
        menuIndex = 0
    }

    func deleteForward() {
        guard editable, cursor < input.count else { return }
        input.remove(at: cursor)
        historyIndex = nil
        menuIndex = 0
    }

    func deleteWord() {
        guard editable, cursor > 0 else { return }
        var start = cursor
        while start > 0, input[start - 1] == " " { start -= 1 } // trailing spaces
        while start > 0, input[start - 1] != " " { start -= 1 } // the word
        input.removeSubrange(start ..< cursor)
        cursor = start
        historyIndex = nil
        menuIndex = 0
    }

    func clearInput() {
        input.removeAll()
        cursor = 0
        pendingBytes.removeAll()
        historyIndex = nil
        menuIndex = 0
    }

    func setInput(_ text: String) {
        input = Array(text)
        cursor = input.count
        pendingBytes.removeAll()
    }

    func cursorLeft() {
        if config != nil, !configEditingImage { config?.switchTab(-1); return }
        if modelHub != nil, modelHub?.select.picking == nil, !modelEditingIdle { switchModelHubTab(-1); return }
        if editable { cursor = max(0, cursor - 1) }
    }

    func cursorRight() {
        if config != nil, !configEditingImage { config?.switchTab(1); return }
        if modelHub != nil, modelHub?.select.picking == nil, !modelEditingIdle { switchModelHubTab(1); return }
        if editable { cursor = min(input.count, cursor + 1) }
    }

    // With an empty input box, Home/End have nothing to move within, so they jump the transcript.
    func cursorHome() { if editable { input.isEmpty ? scrollToTop() : (cursor = 0) } }
    func cursorEnd() { if editable { input.isEmpty ? scrollToLatest() : (cursor = input.count) } }

    /// Move the cursor one word left/right (Option/Alt + arrow, or Alt-b / Alt-f), using the same
    /// whitespace word boundaries as ``deleteWord``.
    func cursorWordLeft() {
        guard editable, cursor > 0 else { return }
        var index = cursor
        while index > 0, input[index - 1] == " " { index -= 1 }
        while index > 0, input[index - 1] != " " { index -= 1 }
        cursor = index
    }

    func cursorWordRight() {
        guard editable, cursor < input.count else { return }
        var index = cursor
        while index < input.count, input[index] == " " { index += 1 }
        while index < input.count, input[index] != " " { index += 1 }
        cursor = index
    }

    func historyUp() {
        guard editable, !history.isEmpty else { return }
        if historyIndex == nil { draft = input; historyIndex = history.count - 1 } else { historyIndex = max(0, historyIndex! - 1) }
        setInput(history[historyIndex!])
    }

    func historyDown() {
        guard editable, let index = historyIndex else { return }
        if index < history.count - 1 {
            historyIndex = index + 1
            setInput(history[index + 1])
        } else {
            historyIndex = nil
            input = draft
            cursor = input.count
        }
    }

    /// Lay the raw input out into visual rows, honoring hard newlines and wrapping by display width at
    /// word boundaries (a word that won't fit moves whole to the next line, rather than splitting
    /// mid-word; a word longer than a line still hard-breaks). Returns each row's characters, every
    /// character's rendered (row, col) - tracked individually so a caret stays exact even when its word
    /// is pushed down - and the trailing column after the last character. Shared by ``layoutInput``
    /// (caret mapping for the renderer) and ``verticalCursorIndex`` (up/down line motion).
    func inputLayout(_ chars: [Character], width: Int)
        -> (rows: [[Character]], positions: [(row: Int, col: Int)], lastCol: Int) {
        let width = max(1, width)
        var rows: [[Character]] = []
        var current: [Character] = []
        var col = 0
        // Each character's rendered (row, col), so the caret maps exactly even after a word is moved.
        var positions: [(row: Int, col: Int)] = []
        positions.reserveCapacity(chars.count)
        // Where the current unbroken word begins on this line (index into `current`, and its column).
        var wordStart = 0
        var wordStartCol = 0

        for char in chars {
            if char == "\n" {
                positions.append((rows.count, col))
                rows.append(current)
                current = []; col = 0; wordStart = 0; wordStartCol = 0
                continue
            }
            let charWidth = TextWidth.of(char)
            if col + charWidth > width {
                if char != " ", wordStartCol > 0 { // word wrap: push the line's trailing word down
                    let moved = current.count - wordStart
                    rows.append(Array(current[..<wordStart]))
                    let suffix = Array(current[wordStart...])
                    var newCol = 0
                    for offset in 0 ..< moved {
                        positions[positions.count - moved + offset] = (rows.count, newCol)
                        newCol += TextWidth.of(suffix[offset])
                    }
                    current = suffix; col = newCol
                } else { // a space, or a word too long for any line: hard break here
                    rows.append(current); current = []; col = 0
                }
                wordStart = 0; wordStartCol = 0
            }
            positions.append((rows.count, col))
            current.append(char)
            col += charWidth
            if char == " " { wordStart = current.count; wordStartCol = col } // next word starts after it
        }
        rows.append(current)
        return (rows, positions, col)
    }

    /// Lay the input out (see ``inputLayout``) and report the cursor's (row, col) within the rows. A
    /// caret past a full line moves to a fresh next row.
    func layoutInput(_ chars: [Character], width: Int, cursor: Int) -> (rows: [String], line: Int, col: Int) {
        let width = max(1, width)
        let layout = inputLayout(chars, width: width)
        var rows = layout.rows
        var caretLine: Int
        var caretCol: Int
        if cursor < layout.positions.count {
            (caretLine, caretCol) = layout.positions[cursor]
        } else {
            caretLine = rows.count - 1; caretCol = layout.lastCol // cursor sits at the very end
        }
        if caretCol >= width { caretLine += 1; caretCol = 0 } // caret past a full line -> next row
        while rows.count <= caretLine { rows.append([]) }
        return (rows.map { String($0) }, caretLine, caretCol)
    }

    /// The input box's inner text column count, matching ``ChatScreen/render()``'s `textWidth` - what
    /// ``layoutInput`` wraps to when the box is drawn. Vertical cursor motion lays the input out at this
    /// same width so the caret moves between the visual rows the user actually sees.
    var inputTextWidth: Int { max(4, cols - 10) }

    /// The cursor index reached by moving the caret one visual row up/down within the (wrapped,
    /// possibly multi-line) input, keeping the column as close to the current one as the destination
    /// row allows. Returns nil when there's no row in that direction, so the caller recalls prompt
    /// history instead - the familiar single-line behavior at the top/bottom edge.
    func verticalCursorIndex(up: Bool, width: Int) -> Int? {
        let width = max(1, width)
        let layout = inputLayout(input, width: width)
        // The caret (row, col) for a cursor index: a character's own position, or - at the very end -
        // the trailing column, wrapping to the next row when it filled the last line.
        func caret(at index: Int) -> (row: Int, col: Int) {
            if index < layout.positions.count { return layout.positions[index] }
            var row = layout.rows.count - 1, col = layout.lastCol
            if col >= width { row += 1; col = 0 }
            return (row, col)
        }
        let here = caret(at: cursor)
        let targetRow = here.row + (up ? -1 : 1)
        guard targetRow >= 0, targetRow < layout.rows.count else { return nil }
        var best = cursor
        var bestDistance = Int.max
        for index in 0 ... input.count {
            let spot = caret(at: index)
            guard spot.row == targetRow else { continue }
            let distance = abs(spot.col - here.col)
            if distance < bestDistance { bestDistance = distance; best = index }
        }
        return best
    }

    // MARK: - Scroll position

    func scroll(by delta: Int) {
        let maxOffset = max(0, totalLines - scrollViewport) // the boxed-menu viewport is shorter
        scrollOffset = min(maxOffset, max(0, scrollOffset + delta))
    }

    func scrollToLatest() { scrollOffset = 0 } // follow the newest output again
    func scrollToTop() { scrollOffset = max(0, totalLines - scrollViewport) }

    // MARK: - File mentions

    /// The `@...` token the cursor is in (start index + the query after `@`), or nil.
    var atToken: (start: Int, query: String)? {
        guard cursor > 0 else { return nil }
        var start = cursor
        while start > 0, input[start - 1] != " ", input[start - 1] != "\n" { start -= 1 }
        guard start < cursor, input[start] == "@" else { return nil }
        return (start, String(input[(start + 1) ..< cursor]))
    }

    var fileMatches: [String] {
        guard let token = atToken else { return [] }
        return fuzzyFiles(token.query)
    }

    var fileMenuActive: Bool { modelHub == nil && !busy && atToken != nil && !fileMatches.isEmpty }
    var fileMenuSelection: Int { min(max(0, fileMenuIndex), max(0, fileMatches.count - 1)) }

    /// Replace the `@token` at the cursor with the highlighted file path, keeping the `@` sigil so it
    /// stays a styled mention chip in the input (and in the sent message), plus a trailing space.
    func selectFile() {
        guard let token = atToken, fileMenuSelection < fileMatches.count else { return }
        let mention = "@" + fileMatches[fileMenuSelection]
        input.replaceSubrange(token.start ..< cursor, with: Array(mention + " "))
        cursor = token.start + mention.count + 1
        fileMenuIndex = 0
        historyIndex = nil
    }

    /// Working-directory entries (top level plus one level deep, hidden / git skipped), scanned once.
    private func fuzzyFiles(_ query: String) -> [String] {
        if cwdFiles == nil { cwdFiles = Self.scanFiles() }
        let files = cwdFiles ?? []
        guard !query.isEmpty else { return Array(files.prefix(8)) }
        let needle = query.lowercased()
        return files.filter { Self.isSubsequence(needle, $0.lowercased()) }
            .sorted { $0.count < $1.count }
            .prefix(8).map { $0 }
    }

    private nonisolated static func scanFiles() -> [String] {
        let manager = FileManager.default
        let root = manager.currentDirectoryPath
        var results: [String] = []
        guard let top = try? manager.contentsOfDirectory(atPath: root) else { return [] }
        for entry in top.sorted() where !entry.hasPrefix(".") {
            results.append(entry)
            var isDir: ObjCBool = false
            if manager.fileExists(atPath: root + "/" + entry, isDirectory: &isDir), isDir.boolValue,
               let children = try? manager.contentsOfDirectory(atPath: root + "/" + entry) {
                for child in children.sorted().prefix(40) where !child.hasPrefix(".") {
                    results.append(entry + "/" + child)
                }
            }
            if results.count > 600 { break }
        }
        return results
    }

    private nonisolated static func isSubsequence(_ needle: String, _ haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for char in needle {
            var found = false
            while let next = iterator.next() {
                if next == char { found = true; break }
            }
            if !found { return false }
        }
        return true
    }
}
