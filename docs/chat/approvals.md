# Approvals & permission modes

Ripple gates certain tool calls with an approval card before they execute. This gives you visibility into what the agent is about to do and control over whether it proceeds. The gating behavior is tunable with permission modes, which you can cycle live with ++tab++.

---

## Which tools are gated

Four built-in tools show an approval card by default:

| Tool | What it does |
|---|---|
| `shell` | Runs a shell command (in the sandbox or locally, depending on config) |
| `read_file` | Reads the content of a file from disk |
| `write_file` | Writes or creates a file on disk |
| `edit_file` | Applies a targeted edit to an existing file |

MCP server tools are also gated by default. Each server has its own `approvalMode` (`ask`, `approve`, or `deny`) that controls whether its tools show the card. See [MCP servers](../mcp.md) for per-server configuration.

---

## The approval card

When a gated tool call is triggered, a card appears in the chat showing:

- The tool name and the arguments the agent intends to pass (e.g. the command string, file path, or edit content).
- Three action choices.

For most tools:

| Choice | Key | Effect |
|---|---|---|
| Approve | ++a++ or ++y++ | Allow this one call and continue |
| Reject | ++r++, ++d++, or ++n++ | Deny this call; the agent is told the tool was rejected |
| Always-Allow | ++shift+a++ | Approve this call and auto-approve all future calls to this tool for the session |

For `shell` specifically, the third choice is **Edit** instead of Always-Allow:

| Choice | Key | Effect |
|---|---|---|
| Approve | ++a++ or ++y++ | Run the command as shown |
| Reject | ++r++, ++d++, or ++n++ | Deny the command |
| Edit | ++e++ | Open the command for inline editing before running |

Additional navigation and confirmation keys:

| Key | Effect |
|---|---|
| ++enter++ | Confirm the highlighted choice |
| ++arrow-up++ / ++arrow-down++ | Move between choices |
| ++esc++ | Deny the pending approval and close the card |

!!! tip
    Use ++shift+a++ (Always-Allow) for tools you trust unconditionally for the current session - for example, `read_file` during a read-heavy research task. This avoids repeated prompts without permanently changing your config. Always-Allow is session-scoped and resets when you quit.

---

## Permission modes

Permission modes let you adjust the approval policy for an entire session without editing config files. Cycle through modes with ++tab++ at the prompt. The current mode is shown in the status line.

| Mode | Status line color | Behavior |
|---|---|---|
| `ask` | Green | Prompt for every gated tool call. This is the default. |
| `auto-reads` | Amber | Auto-approve `read_file` and directory listings; prompt for writes and shell. |
| `plan` | Blue | Dry run: auto-approve reads, auto-reject writes. Nothing on disk changes. |
| `accept-all` | Red ("YOLO") | Approve every tool call automatically, no prompts. |

### `ask` (default, green)

Every gated call shows the approval card. Use this when working in an unfamiliar codebase or when you want to review every action the agent takes.

### `auto-reads` (amber)

Read operations (`read_file`, `ls`) are approved automatically so the agent can explore freely. Write operations and shell commands still require confirmation. A good balance for most interactive coding sessions.

### `plan` (blue)

The agent can read anything but cannot write or execute. This is a safe mode for previewing what the agent would do: let it reason, read files, and build a plan, then switch back to `ask` or `auto-reads` when you're ready to act.

!!! note
    In `plan` mode, auto-rejected write tool calls tell the agent the tool was denied. A well-behaved agent will list what it would have written instead of silently stopping.

### `accept-all` (red, "YOLO")

All tool calls are approved without prompting. Because this is a high-trust mode with significant consequences, it requires a **two-step confirmation**:

1. Press ++tab++ until the mode indicator turns red and shows "YOLO" with an "armed" state.
2. Press ++tab++ a second time to confirm and activate.

Press ++esc++ at any point during arming to disarm and return to the previous mode.

!!! warning
    `accept-all` gives the agent unrestricted access to your filesystem and shell. Use it only for well-understood automation tasks in a safe environment, or inside the sandbox. See [Sandbox & shell](../sandbox.md).

---

## Relation to `toolPolicy.approvals` and the sandbox

Permission modes are a session-level overlay on top of the persistent `toolPolicy.approvals` config. The resolved policy for a call is determined by combining:

1. **`toolPolicy.approvals`** in `settings.json` - static per-tool policy (`ask`, `approve`, or `deny`).
2. **Active permission mode** - raises the floor for the session (e.g. `auto-reads` implicitly approves reads even if `toolPolicy` says `ask`).
3. **Always-Allow choices** made during the session - session-scoped per-tool overrides.

The [Sandbox & shell](../sandbox.md) configuration determines where approved `shell` calls actually execute (container vs. local host). The approval system and the sandbox are independent: an approved shell call still runs in the sandbox when `sandbox` is set to `failover` or `container-only`.

See [Configuration (overview)](../config/index.md) for the full `toolPolicy` schema.
