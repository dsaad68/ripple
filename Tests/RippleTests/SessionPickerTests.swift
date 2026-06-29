@testable import ripple
import Testing

/// The interactive `ripple --resume` picker's two pure helpers: the keystroke decoder (arrows / Enter
/// / cancel / abort) and the scroll window. The raw-mode draw loop itself needs a tty, so only these
/// deterministic pieces are unit-tested.
struct SessionPickerTests {
    @Test func decodeMapsArrowKeysFromBothCsiAndSs3() {
        #expect(SessionPicker.decode([0x1B, 0x5B, 0x41]) == .up) // ESC [ A
        #expect(SessionPicker.decode([0x1B, 0x5B, 0x42]) == .down) // ESC [ B
        #expect(SessionPicker.decode([0x1B, 0x4F, 0x41]) == .up) // ESC O A (application cursor keys)
        #expect(SessionPicker.decode([0x1B, 0x4F, 0x42]) == .down) // ESC O B
        #expect(SessionPicker.decode([0x6B]) == .up) // k
        #expect(SessionPicker.decode([0x6A]) == .down) // j
    }

    @Test func decodeMapsSelectCancelAndAbort() {
        #expect(SessionPicker.decode([0x0D]) == .select) // Enter (CR)
        #expect(SessionPicker.decode([0x0A]) == .select) // Enter (LF)
        #expect(SessionPicker.decode([0x1B]) == .cancel) // a bare Escape
        #expect(SessionPicker.decode([0x71]) == .cancel) // q
        #expect(SessionPicker.decode([0x6E]) == .cancel) // n
        #expect(SessionPicker.decode([0x04]) == .cancel) // Ctrl-D
        #expect(SessionPicker.decode([]) == .cancel) // EOF -> start fresh
        #expect(SessionPicker.decode([0x03]) == .abort) // Ctrl-C aborts the program
    }

    @Test func decodeIgnoresUnhandledInput() {
        #expect(SessionPicker.decode([0x7A]) == .ignore) // some other letter (z)
        #expect(SessionPicker.decode([0x1B, 0x5B, 0x43]) == .ignore) // Right arrow - not navigation here
        #expect(SessionPicker.decode([0x61, 0x62, 0x63]) == .ignore) // a multi-byte paste
    }

    @Test func windowStartStaysAtZeroWhenListFits() {
        #expect(SessionPicker.windowStart(count: 3, height: 5, selected: 2) == 0)
        #expect(SessionPicker.windowStart(count: 5, height: 5, selected: 4) == 0)
    }

    @Test func windowStartRecentersAndClampsInsideTheList() {
        #expect(SessionPicker.windowStart(count: 10, height: 4, selected: 0) == 0) // top
        #expect(SessionPicker.windowStart(count: 10, height: 4, selected: 5) == 3) // re-centered
        #expect(SessionPicker.windowStart(count: 10, height: 4, selected: 9) == 6) // clamped to the end
    }

    @Test func windowStartAlwaysKeepsTheSelectionVisible() {
        for selected in 0 ..< 12 {
            let start = SessionPicker.windowStart(count: 12, height: 5, selected: selected)
            #expect(start <= selected && selected < start + 5)
        }
    }
}
