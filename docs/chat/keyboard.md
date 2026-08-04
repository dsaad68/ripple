# Keyboard reference

A complete reference for all keyboard shortcuts in `ripple chat`. Keys are grouped by function. For mouse support, see the note at the bottom of the page.

---

## Text editing

These shortcuts work at the chat input prompt while typing a message.

| Key | Action |
|---|---|
| ++ctrl+a++ | Move cursor to the beginning of the line |
| ++ctrl+e++ | Move cursor to the end of the line |
| ++ctrl+u++ | Clear the entire input line |
| ++ctrl+w++ | Delete the word to the left of the cursor |
| ++alt+left++ | Move cursor one word to the left |
| ++alt+right++ | Move cursor one word to the right |
| ++alt+enter++ | Insert a newline (multi-line input) |

---

## Session and turn control

| Key | Action |
|---|---|
| ++ctrl+c++ | Cancel the running agent turn (if one is in progress), or quit if the prompt is idle |
| ++ctrl+d++ | Quit Ripple (same as `/quit`) |
| ++esc++ | Deny a pending approval card and close it, or close an open overlay, or clear the input |

!!! tip
    ++ctrl+c++ during a running turn stops the agent and returns you to the prompt. The turn's partial output remains visible in the transcript. Press ++ctrl+c++ again at the idle prompt to quit.

---

## Transcript navigation

These shortcuts scroll the conversation transcript above the input.

| Key | Action |
|---|---|
| ++arrow-up++ | Scroll up one line (when no overlay is open) |
| ++arrow-down++ | Scroll down one line |
| ++page-up++ | Scroll up one page |
| ++page-down++ | Scroll down one page |

When the slash command palette or a tool overlay (e.g. `/model`, `/tools`) is open, ++arrow-up++ and ++arrow-down++ navigate within the overlay instead.

---

## Approval cards

When an approval card is shown for a gated tool call:

| Key | Action |
|---|---|
| ++a++ or ++y++ | Approve this call |
| ++r++, ++d++, or ++n++ | Reject this call |
| ++shift+a++ | Always-Allow - approve this call and all future calls to this tool for the session |
| ++e++ | Edit the command (shell tool only) |
| ++enter++ | Confirm the highlighted choice |
| ++arrow-up++ / ++arrow-down++ | Move between approval choices |
| ++esc++ | Deny the pending approval and dismiss the card |

---

## Permission modes

| Key | Action |
|---|---|
| ++tab++ | Cycle the permission mode: `ask` -> `auto-reads` -> `plan` -> `accept-all` -> `ask` |
| ++tab++ (second press, when armed at `accept-all`) | Confirm and activate `accept-all` ("YOLO") mode |
| ++esc++ (when `accept-all` is armed but not confirmed) | Disarm and return to the previous mode |

The current mode is shown in the status line with a color indicator: green (`ask`), amber (`auto-reads`), blue (`plan`), red (`accept-all`). See [Approvals & permission modes](approvals.md) for a full description of each mode.

---

## Mouse support

Ripple's TUI supports mouse input in terminals that report mouse events. You can:

- **Click links** in the transcript to open them (URLs rendered in Markdown output).
- **Click panes** (e.g. the plan panel header) to expand or collapse them.
- **Click sidebar items** when overlays such as the `/model` picker or `/tools` browser are open.

Mouse support depends on your terminal emulator's capabilities. If clicks don't register, check that mouse reporting is enabled in your terminal settings.
