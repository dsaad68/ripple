# Interactive chat (overview)

`ripple chat` (or bare `ripple`) opens a full terminal UI built around a single deep-agent loop. This page describes the screen layout, how a turn progresses from prompt to answer, and how the agent uses tools. The subpages cover each major feature in detail.

## Screen layout

The TUI is divided into four regions, top to bottom:

```text
┌──────────────────────────────────────────────────────────────┐
│ STATUS LINE   LFM2.5-1.2B  ·  ask  ·  ~/projects/my-app  44%│  <- context meter
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  TRANSCRIPT                                                  │  <- scrollable history
│  (markdown, code blocks, tool call results)                  │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  PLAN PANEL                                     [v]          │  <- pinned, collapsible
│  ├─ [x] Read NetworkManager.swift                            │
│  ├─ [ ] Identify callback APIs                               │
│  └─ [ ] Rewrite with async/await                             │
├──────────────────────────────────────────────────────────────┤
│ > _                                                          │  <- input box
└──────────────────────────────────────────────────────────────┘
```

### Status line

The top bar shows, from left to right:

- **Active model** - the planner model id (local MLX or registered remote name)
- **Permission mode** - `ask` (green) / `auto-reads` (amber) / `plan` (blue) / `accept-all` (red)
- **Working directory** - the directory `ripple` was launched from
- **Context meter** - percentage of the model's context window consumed so far

The context meter updates after every turn. When it approaches 85%, the [compaction middleware](../config/compaction.md) fires automatically and the meter drops. You can also trigger it manually with `/compact`.

### Transcript

The main scrollable area shows the full conversation history for the current session:

- **User messages** are shown as-is.
- **Assistant responses** are rendered as Markdown with syntax-highlighted code blocks, tables, and lists.
- **Tool calls** are shown inline with their arguments and results.
- **Thinking blocks** collapse to `Thought for Xs` once the reasoning phase completes; click or navigate to the block to expand it.
- **Compaction notes** appear as dimmed system notes when the context was summarized.
- **Failures** are never silent: a turn that dies mid-generation (a model that could not
  (re)load, a generation error) ends with a red `✗ turn failed - <reason>` line under whatever
  streamed before it, and a model problem at launch or on a `/model` switch is reported as a
  system note. See [Load-failure behavior](../models/local.md#load-failure-behavior).

Scroll with the arrow keys, ++page-up++ / ++page-down++, or the mouse. Click links in the transcript to open them.

### Plan panel

The plan panel is pinned between the transcript and the input box. It shows the agent's current todo list, updated live as the agent works through a task. Each item is prefixed with `[ ]` (pending) or `[x]` (done).

Click the `[v]` header or press the collapse binding (see [Keyboard reference](keyboard.md)) to toggle the panel. Collapsing it gives more vertical space to the transcript without losing the live plan.

!!! note "When the plan panel is empty"
    Not every model produces an explicit plan. The panel only appears when the agent emits plan items. On the 1.2B model, shorter tasks may produce no plan; on larger or remote models it is more consistent.

### Input box

The single-line input at the bottom of the screen accepts:

- **Prose prompts** - sent to the agent on ++enter++
- **Slash commands** - type `/` to open the command palette; arrow keys navigate, ++enter++ runs
- **`@` file mentions** - type `@` to fuzzy-match files in the working directory and inline their content
- **`!cmd` shell commands** - run directly in the container sandbox (bypasses the agent)
- **`!!cmd` shell commands** - run in the local shell (bypasses both the agent and the sandbox)

Press ++alt+enter++ for a newline inside the input box.

---

## The turn lifecycle

A turn starts when you press ++enter++ on a non-empty prompt and ends when the agent emits its final message and the input box becomes active again.

```text
User presses Enter
      │
      ▼
  [Thinking]        <- model reasons; live stream collapses to "Thought for Xs"
      │
      ▼
  [Plan update]     <- plan panel refreshes with new or checked-off items
      │
      ├── [Tool call] ──> [Approval card] ──> approved/rejected
      │       │
      │       └── [Tool result] ──> back to reasoning
      │
      ▼
  [Final answer]    <- streams into transcript; markdown rendered live
      │
      ▼
  Input box active
```

The loop continues until the model stops calling tools and emits a final response. The number of iterations is bounded by `max_iterations` (default 24 for scenario runs; the interactive REPL has no hard cap).

---

## How the agent uses tools

The agent has access to several built-in tool groups, plus any tools from connected [MCP servers](../mcp.md):

| Group | Tools |
|---|---|
| Filesystem | `read_file`, `write_file`, `edit_file`, `list_directory` |
| Shell | `shell` (sandboxed or local, depending on mode) |
| Apple Notes | Read, search, and create notes |
| Clipboard | Read from and write to the macOS clipboard |
| Vision | Screenshot and analyze windows or the full screen |

Each tool group is a "capability middleware" - you can disable individual groups in `/config` or via `settings.json`.

Gated tools (shell, reads, writes) pause the turn and show an [approval card](approvals.md) unless the permission mode bypasses them. The `/tools` command lists every tool currently available to the agent, grouped by capability.

---

## Section tour

| Page | What it covers |
|---|---|
| [Slash commands](slash-commands.md) | All `/` commands: model picker, tools browser, MCP inspector, config, compact, reset |
| [Shell and file mentions](shell-and-mentions.md) | `!cmd` / `!!cmd` shell escapes and `@file` fuzzy inlining |
| [Approvals and permission modes](approvals.md) | The approval card UI, approval keys, and the four permission modes cycled with ++tab++ |
| [Plan panel and thinking](plan-and-thinking.md) | The live plan panel, thinking stream, and how to navigate collapsed thoughts |
| [Keyboard reference](keyboard.md) | Complete keybinding table: navigation, editing, approval, mode cycling |
