import DeepAgents
import Foundation

/// How much color the terminal supports, detected once from the environment.
enum ColorDepth { case none, ansi256, truecolor }

/// The chat UI's semantic palette. Each role carries a 24-bit RGB (used on truecolor terminals) and a
/// 256-color fallback index identical to the value the UI used before the theme existed - so 256-color
/// terminals render exactly as they did, while truecolor terminals get the tuned RGB and `NO_COLOR`
/// gets no escapes at all. Render code refers to roles (`Theme.muted`, `Theme.accent`, ...) and the
/// raw indices keep working through ``byXterm``.
enum Theme {
    struct Color: Sendable { let r, g, b: UInt8; let xterm: Int }

    /// Detected once at launch; overridable in tests.
    nonisolated(unsafe) static var depth: ColorDepth = detectDepth()

    static func detectDepth() -> ColorDepth {
        let env = ProcessInfo.processInfo.environment
        if env["NO_COLOR"] != nil { return .none }
        if env["TERM"] == "dumb" { return .none }
        let colorterm = (env["COLORTERM"] ?? "").lowercased()
        if colorterm.contains("truecolor") || colorterm.contains("24bit") { return .truecolor }
        return .ansi256
    }

    // Greys (text down to box borders).
    static let bright = Color(r: 0xF1, g: 0xF2, b: 0xF4, xterm: 255)
    static let text = Color(r: 0xD2, g: 0xD6, b: 0xDC, xterm: 252)
    static let body = Color(r: 0xC4, g: 0xC9, b: 0xD0, xterm: 253)
    static let dim = Color(r: 0xA7, g: 0xAD, b: 0xB6, xterm: 250)
    static let subtle = Color(r: 0x97, g: 0x9D, b: 0xA7, xterm: 245)
    static let muted = Color(r: 0x84, g: 0x8A, b: 0x94, xterm: 244)
    static let faint = Color(r: 0x55, g: 0x5B, b: 0x65, xterm: 240)
    static let border = Color(r: 0x3B, g: 0x40, b: 0x48, xterm: 238)
    static let userBg = Color(r: 0x25, g: 0x29, b: 0x30, xterm: 236)

    // Accents.
    static let accent = Color(r: 0x6C, g: 0xB6, b: 0xFF, xterm: 111) // blue (arrows, focus)
    static let agent = Color(r: 0xBD, g: 0x9C, b: 0xFF, xterm: 141) // purple (thought / plan / delegate)
    static let success = Color(r: 0x8C, g: 0xE0, b: 0x86, xterm: 114) // green (done / approve)
    static let danger = Color(r: 0xFF, g: 0x8C, b: 0x80, xterm: 174) // red (errors / reject)
    static let mutedSuccess = Color(r: 0x6E, g: 0x9C, b: 0x6A, xterm: 108) // muted green (a governed row's "on")
    static let mutedDanger = Color(r: 0xBE, g: 0x77, b: 0x71, xterm: 131) // muted red (a governed row's "off")
    static let warn = Color(r: 0xF3, g: 0xC1, b: 0x6B, xterm: 179) // amber (spinner / tools)
    static let code = Color(r: 0xFF, g: 0xB4, b: 0x70, xterm: 215) // inline code
    static let codeBlock = Color(r: 0x74, g: 0xB6, b: 0xBB, xterm: 109) // fenced code
    static let link = Color(r: 0x73, g: 0xBB, b: 0xFF, xterm: 75) // links

    /// All roles, for the reverse lookup. Order matters only for duplicate xterm indices (none here).
    private static let all = [
        bright, text, body, dim, subtle, muted, faint, border, userBg,
        accent, agent, success, danger, mutedSuccess, mutedDanger, warn, code, codeBlock, link
    ]

    /// Maps a legacy 256-color index to its role, so call sites that still pass a raw index pick up the
    /// truecolor RGB and `NO_COLOR` handling for free.
    static let byXterm: [Int: Color] = {
        var map: [Int: Color] = [:]
        for color in all where map[color.xterm] == nil { map[color.xterm] = color }
        return map
    }()

    static func color(forXterm index: Int) -> Color {
        byXterm[index] ?? Color(r: 0, g: 0, b: 0, xterm: index)
    }
}

/// ANSI helpers, depth-aware: truecolor terminals get `38;2;r;g;b`, 256-color terminals the legacy
/// index, and `NO_COLOR` no escape at all. Background-aware variants reset only the foreground (`39`)
/// so a colored run keeps the box background until the line's final reset.
enum Paint {
    static func fg(_ index: Int, _ s: String) -> String { paint(fgSeq(Theme.color(forXterm: index)), s) }
    static func fg(_ color: Theme.Color, _ s: String) -> String { paint(fgSeq(color), s) }

    static func fgRaw(_ index: Int, _ s: String) -> String {
        let seq = fgSeq(Theme.color(forXterm: index))
        return seq.isEmpty ? s : seq + s + "\u{1B}[39m"
    }

    static func bold(_ s: String) -> String { Theme.depth == .none ? s : "\u{1B}[1m\(s)\u{1B}[22m" }

    /// A `@file` mention styled as a distinct token - bold + underlined in the path-like "code" accent,
    /// so a file picked from the `@` adder reads as a chip rather than ordinary input text. Merged into
    /// one SGR run that ends with a full reset; a no-op under `NO_COLOR` (the literal `@path` still shows).
    static func mention(_ s: String) -> String {
        guard let params = fgParams(Theme.code) else { return s }
        return "\u{1B}[1;4;\(params)m" + s + "\u{1B}[0m"
    }

    static func arrow(_ s: String) -> String {
        let seq = fgSeq(Theme.accent)
        if seq.isEmpty { return s }
        return "\u{1B}[1m" + seq + s + "\u{1B}[0m"
    }

    static func bgFg(_ bg: Int, _ fg: Int, _ s: String) -> String {
        let seq = bgSeq(Theme.color(forXterm: bg)) + fgSeq(Theme.color(forXterm: fg))
        return seq.isEmpty ? s : seq + s + "\u{1B}[0m"
    }

    static func bgEdge(_ bg: Int, _ s: String) -> String { bgFg(bg, Theme.faint.xterm, s) }

    static func bgArrow(_ bg: Int) -> String {
        let seq = bgSeq(Theme.color(forXterm: bg)) + fgSeq(Theme.accent)
        if seq.isEmpty { return "❯" }
        return "\u{1B}[1m" + seq + "❯\u{1B}[0m"
    }

    /// A foreground SGR introducer for a role, without the trailing reset (for composing runs).
    static func fgSeq(_ color: Theme.Color) -> String {
        fgParams(color).map { "\u{1B}[\($0)m" } ?? ""
    }

    /// The bare SGR parameters for a foreground role (e.g. "38;2;r;g;b"), or nil under `NO_COLOR` -
    /// for merging the color with other attributes (bold/italic/underline) into one escape.
    static func fgParams(_ color: Theme.Color) -> String? {
        switch Theme.depth {
        case .none: return nil
        case .ansi256: return "38;5;\(color.xterm)"
        case .truecolor: return "38;2;\(color.r);\(color.g);\(color.b)"
        }
    }

    private static func bgSeq(_ color: Theme.Color) -> String {
        switch Theme.depth {
        case .none: return ""
        case .ansi256: return "\u{1B}[48;5;\(color.xterm)m"
        case .truecolor: return "\u{1B}[48;2;\(color.r);\(color.g);\(color.b)m"
        }
    }

    /// Lay `s` on a solid background that survives the string's own resets: every full reset (`[0m`)
    /// inside `s` re-asserts the background, so each segment keeps its own foreground / bold while the
    /// band runs unbroken to a final reset. Used for a selected menu row's highlight band; the caller
    /// supplies any padding inside `s` so the whole row width is filled. No-op under `NO_COLOR`.
    static func onBackground(_ s: String, _ bg: Theme.Color) -> String {
        let seq = bgSeq(bg)
        guard !seq.isEmpty else { return s }
        return seq + s.replacingOccurrences(of: "\u{1B}[0m", with: "\u{1B}[0m" + seq) + "\u{1B}[0m"
    }

    private static func paint(_ seq: String, _ s: String) -> String {
        seq.isEmpty ? s : seq + s + "\u{1B}[0m"
    }

    /// Color `s` along a left-to-right gradient between two roles (truecolor only; on 256-color it
    /// falls back to a solid `from`, and to nothing under NO_COLOR).
    static func gradient(_ s: String, from: Theme.Color, to: Theme.Color) -> String {
        let chars = Array(s)
        guard Theme.depth == .truecolor, chars.count > 1 else { return fg(from, s) }
        func lerp(_ a: UInt8, _ b: UInt8, _ t: Double) -> Int { Int((Double(a) + (Double(b) - Double(a)) * t).rounded()) }
        var out = ""
        for (index, char) in chars.enumerated() {
            let t = Double(index) / Double(chars.count - 1)
            out += "\u{1B}[38;2;\(lerp(from.r, to.r, t));\(lerp(from.g, to.g, t));\(lerp(from.b, to.b, t))m\(char)"
        }
        return out + "\u{1B}[0m"
    }
}
