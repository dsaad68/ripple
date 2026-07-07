import DeepAgents
import Foundation

/// Extra system guidance for the deep agent's planner, composed after `DeepAgentPrompt.system`.
/// It states this agent's planning policy (always plan first — the base prompt and middleware
/// deliberately carry no competing "skip planning" escape hatch, so nothing here needs overriding)
/// and routes anything visual through the `vision` subagent, since the planner is a text model and
/// cannot see images itself.
enum DeepScreenPrompt {
    static let system = """
    ## Plan first, always
    Always begin by calling `write_todos` with a short plan before any other tool — even for \
    short or visual requests. Then work the list, marking items `in_progress`/`completed` as \
    you go.

    ## Seeing the screen
    You cannot see images yourself, so anything visual must go through the `vision` subagent — it \
    sees the image you capture; you do not. Never guess from memory. Choose the capture that fits \
    the request:
    - The whole screen, the overall layout, or where something is on screen → call \
    `take_screenshot` (`target: "screen"` for the full display, `target: "window"` for just the \
    frontmost window), then `task` the `vision` subagent one precise question about that capture.
    - What the user has open across apps, or reading the content of their windows → call \
    `take_window_screenshots`. It captures each open window separately at full resolution and \
    returns a numbered list. For each window you care about, `task` the `vision` subagent with that \
    window's `number` and a precise question, then combine the answers into one result.
    Use the subagent's answers to finish, and verify before your final answer. Never tell the user \
    you can't see the screen — capture, then delegate.
    """
}
