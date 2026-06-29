# Quickstart

This guide walks you through your first `ripple chat` session and your first headless one-shot run. It assumes you have completed [Installation](installation.md).

## Interactive: `ripple chat`

### Launch and model selection

Start the interactive REPL from a project directory:

```sh
cd ~/projects/my-app
ripple chat
```

If no `--model` flag is given and no `selectedModel` is stored in `settings.json`, Ripple prompts you to pick a model:

```text
No model selected. Choose one?
  LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16   (cached)
  LiquidAI/LFM2.5-8B-Instruct-MLX-bf16     (not cached - download?)
  [Remote models in settings.json...]

> (arrow keys to select, Enter to confirm)
```

If the chosen model is not cached, Ripple asks whether to download it. Answer `y`, or pass `--yes` to skip the prompt:

```sh
ripple chat --model LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16 --yes
```

### Type a prompt

Once the TUI is running, you'll see the status line at the top showing the active model, permission mode, and working directory, and the input box at the bottom. Type your first prompt and press ++enter++:

```text
> What files are in this project?
```

### Watch the turn unfold

A turn has three visible phases:

1. **Thinking** - the model reasons about what to do. You see a live `thinking...` stream that collapses to `Thought for Xs` when done.
2. **Tool calls** - the agent calls tools (e.g. `list_directory`, `read_file`). Each gated call shows an approval card before executing.
3. **Answer** - the final response streams into the transcript with full markdown rendering, syntax-highlighted code blocks, and tables.

### Approve a tool call

When the agent calls a tool that requires approval (shell commands, file reads, file writes), an approval card appears:

```text
  read_file("src/main.swift")
  ┌─────────────────────────────────────────────────┐
  │  a approve   r reject   A always-allow           │
  └─────────────────────────────────────────────────┘
```

| Key | Action |
|---|---|
| `a` or `y` | Approve this call |
| `r`, `d`, or `n` | Reject this call |
| `A` | Always-allow this tool for the rest of the session |
| `e` | Edit (shell tools only) - modify the command before running |
| ++enter++ | Confirm the highlighted choice |
| ++esc++ | Deny and dismiss |

### Change the permission mode

Rather than responding to every card individually, press ++tab++ to cycle the permission mode shown in the status line:

| Mode | Color | Behavior |
|---|---|---|
| `ask` | green | Prompt for every gated tool call (default) |
| `auto-reads` | amber | Auto-approve reads (`list_directory`, `read_file`); prompt for writes and shell |
| `plan` | blue | Dry run - auto-approve reads, auto-reject writes; nothing on disk changes |
| `accept-all` | red | Approve everything; press ++tab++ a second time to confirm ("YOLO") |

Press ++esc++ to disarm `accept-all` without cycling further.

!!! warning "`accept-all` is powerful"
    In `accept-all` mode the agent can write and delete files, run arbitrary shell commands, and install packages in the sandbox without pausing. Use `plan` mode first to preview what the agent intends to do.

### Use `/help`

Type `/help` to open the command palette with all slash commands and keyboard shortcuts listed. Slash commands are filtered as you type - just type `/` to open the palette, then continue typing to narrow it:

```text
/help
/model      choose & manage models
/tools      list all agent tools
/mcp        list MCP servers and their tools
/config     edit capabilities, sandbox & logging
/compact    summarize older turns to free context
/fresh      start a new conversation
/clear      clear the screen
/exit       quit
```

### Exit

Press ++ctrl+d++ or type `/exit` to quit. Your session is saved automatically - see [Sessions](../config/sessions.md) for how to resume it.

---

## Headless: one-shot prompts

For scripting, CI, or editor integrations, use `ripple -p` to run a single prompt and exit:

```sh
ripple -p "Summarize the TODO comments in src/" \
  --model LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16 \
  --yes
```

`--yes` skips the model download prompt. Without it, Ripple prints a hint and exits if the model is not cached.

### Piped stdin

You can pipe content into the prompt:

```sh
cat error.log | ripple -p "What went wrong?" --yes
```

The stdin content is appended to the prompt. This is useful for summarizing command output or analyzing files too large to pass as a `@mention`.

### Structured output

Use `--output-format` to control how the response is emitted:

| Format | Description |
|---|---|
| `text` | Plain text response, streamed to stdout (default) |
| `json` | Full agent result as a JSON object, emitted on completion |
| `stream-json` | JSON events streamed line-by-line as they arrive |

```sh
ripple -p "List all Swift files" --output-format json --yes | jq '.result'
```

`stream-json` is useful when you want to display progress in a parent process while still parsing the final result.

### Tool policy in headless mode

In headless mode there is no interactive approval card. Use these flags to control tool access:

```sh
# Auto-approve reads, prompt on writes (but there is no TTY - writes will be rejected)
ripple -p "Read the README" --permission-mode auto-reads --yes

# Allow a specific tool without a full mode change
ripple -p "Check disk usage" --allow-tool shell --yes

# Block a tool you don't want used
ripple -p "Explain this code" --deny-tool write_file --yes
```

`--permission-mode` accepts `ask | auto-reads | plan | accept-all`. In headless mode `ask` without a TTY will reject gated calls, so set it to `auto-reads` or higher for tasks that need tool access.

---

## Next steps

- [Interactive chat](../chat/index.md) - full TUI layout, the plan panel, and thinking display
- [Approvals and permission modes](../chat/approvals.md) - detailed reference for the approval system
- [Models](../models/index.md) - local MLX models, remote endpoints, and the model picker
