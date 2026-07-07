import DeepAgents
import Foundation

/// Terminal column width of text, the way a monospace terminal actually renders it: ANSI SGR escapes
/// count for nothing, and wide CJK / emoji graphemes count as two columns. The old code counted one
/// column per Unicode scalar, so any wide character drifted box borders and padding by a column.
enum TextWidth {
    /// Visible column width of `s` (escape sequences skipped).
    static func of(_ s: String) -> Int {
        var total = 0
        var iterator = s.makeIterator()
        while let char = iterator.next() {
            if char == "\u{1B}" { // skip a CSI/SGR sequence: up to and including its final letter
                while let next = iterator.next() {
                    if ("a" ... "z").contains(next) || ("A" ... "Z").contains(next) { break }
                }
                continue
            }
            total += of(char)
        }
        return total
    }

    /// Truncate `s` to at most `width` visible columns, preserving ANSI SGR escapes (they cost no
    /// width and are never cut mid-sequence). When anything is dropped the result ends with a reset +
    /// ellipsis, so a cut color can't bleed onto whatever follows on the row. A safety net for framed
    /// rows whose styled content can't be pre-clipped (escape sequences make a plain ``clip`` unsafe).
    static func truncate(_ s: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        guard of(s) > width else { return s }
        var out = ""
        var visible = 0
        var iterator = s.makeIterator()
        while let char = iterator.next() {
            if char == "\u{1B}" { // copy the whole escape sequence verbatim (it has no width)
                out.append(char)
                while let next = iterator.next() {
                    out.append(next)
                    if ("a" ... "z").contains(next) || ("A" ... "Z").contains(next) { break }
                }
                continue
            }
            let w = of(char)
            if visible + w > width - 1 { break } // keep one column for the ellipsis
            out.append(char)
            visible += w
        }
        return out + "\u{1B}[0m…"
    }

    /// Column width of one grapheme: 2 for wide CJK / emoji, otherwise 1. Combining marks fold into
    /// their base grapheme already, so a cluster's width is driven by its leading scalar.
    static func of(_ char: Character) -> Int {
        for scalar in char.unicodeScalars where scalar.properties.isEmojiPresentation { return 2 }
        guard let first = char.unicodeScalars.first else { return 0 }
        return isWide(first.value) ? 2 : 1
    }

    /// East Asian Wide / Fullwidth scalar ranges (the common ones), plus emoji/pictograph blocks.
    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100 ... 0x115F, // Hangul Jamo
             0x2E80 ... 0x303E, // CJK radicals, Kangxi, CJK symbols & punctuation
             0x3041 ... 0x33FF, // Hiragana .. CJK compatibility
             0x3400 ... 0x4DBF, // CJK Unified Ideographs Extension A
             0x4E00 ... 0x9FFF, // CJK Unified Ideographs
             0xA000 ... 0xA4CF, // Yi syllables
             0xAC00 ... 0xD7A3, // Hangul syllables
             0xF900 ... 0xFAFF, // CJK compatibility ideographs
             0xFE10 ... 0xFE19, // vertical forms
             0xFE30 ... 0xFE6F, // CJK compatibility / small forms
             0xFF00 ... 0xFF60, // fullwidth forms
             0xFFE0 ... 0xFFE6, // fullwidth signs
             0x1F000 ... 0x1FAFF, // mahjong / dominoes / cards / emoji / pictographs
             0x20000 ... 0x3FFFD: // CJK Unified Ideographs Extension B and beyond
            return true
        default:
            return false
        }
    }
}
