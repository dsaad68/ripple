# Command reference

Full reference for `ripple` commands and flags. For conceptual background, see the linked guide
pages.

---

## Top-level usage

```text
ripple [options]             Interactive REPL (no subcommand needed; equivalent to ripple chat)
ripple -p "prompt"           One-shot headless run
ripple chat [options]        Interactive deep-agent REPL (explicit form of bare ripple)
ripple run <scenarios>       Scenario harness (headless batch)
ripple mcp [...]             Manage MCP servers
ripple model [...]           Download and manage local models
ripple --version             Print the ripple and DeepAgents-swift versions
ripple --help                Full usage and project links
```

Bare `ripple` with no subcommand starts an interactive session - you do not need `ripple chat`
(it is the explicit equivalent). With `-p` / `--print` it runs a single prompt headlessly and exits.

`ripple --version` prints the ripple release and the DeepAgents-swift framework version it was built
against, e.g. `ripple 0.2.3 (DeepAgents-swift 0.2.3)`. `ripple --help` ends with links to the
project repos and docs (Ripple and DeepAgents-swift).

---

## Shared options (CommonRunOptions)

These flags are accepted by bare `ripple` and `ripple chat`:

| Flag | Values | Description |
|---|---|---|
| `--model <name>` | HF id or registered name | Planner model to use. Overrides `settings.json`. |
| `--log <dir>` | directory path | Write a JSONL debug transcript to this directory. |
| `--sandbox <mode>` | `off` \| `failover` \| `container-only` | Container sandbox mode. Bare `--sandbox` (no value) defaults to `failover`. See [Sandbox & shell](../sandbox.md). |
| `--yes` / `--download` | flag | Auto-download a missing model instead of prompting. |
| `--resume [id]` | optional UUID | Resume a past session. Bare `--resume` opens the project session picker (most-recent first). `--resume <id>` resumes a specific session by UUID. |

---

## Headless-only flags

These flags are only valid when running headlessly (`ripple -p` or piped stdin). They are rejected
if you try to use them with `ripple chat`.

| Flag | Values | Description |
|---|---|---|
| `-p` / `--print <prompt>` | string | Prompt for a one-shot run. Also accepts piped stdin. |
| `--output-format <fmt>` | `text` \| `json` \| `stream-json` | Output format. Default: `text`. `json` emits a single JSON object on completion; `stream-json` emits newline-delimited JSON events as they arrive. |
| `--permission-mode <mode>` | `ask` \| `auto-reads` \| `plan` \| `accept-all` | Initial permission mode. Default: `ask`. See [Approvals & permission modes](../chat/approvals.md). |
| `--allow-tool <name>` | tool name | Auto-approve this tool for the run. Repeatable. |
| `--deny-tool <name>` | tool name | Auto-reject this tool for the run. Repeatable. |
| `--disable-middleware <id>` | middleware id | Turn off a capability middleware by id. Repeatable. |
| `--sandbox-image <image>` | OCI image ref | Override the container image. See [Sandbox & shell](../sandbox.md). |

### One-shot examples

```sh
# Simple one-shot
ripple -p "Summarize the README in three bullets"

# Piped stdin
cat README.md | ripple -p "Summarize this"

# JSON output, auto-approve reads, deny writes
ripple -p "List files in src/" \
  --output-format json \
  --permission-mode auto-reads \
  --deny-tool write_file

# Headless with a remote model
ripple -p "What is 2 + 2?" --model open-ai/gpt-5.4-mini --output-format stream-json

# Run in sandbox, disable clipboard middleware
ripple -p "Install and run pytest" \
  --sandbox container-only \
  --disable-middleware clipboard
```

---

## `ripple chat`

```text
ripple chat [CommonRunOptions]
```

Starts the interactive TUI. Accepts all [CommonRunOptions](#shared-options-commonrunoptions).
Does not accept headless-only flags.

Inside the TUI, use [slash commands](slash-commands.md) (`/model`, `/mcp`, `/config`, `/compact`,
`/tools`, `/help`, `/fresh`, `/reset`, `/clear`, `/exit`) and [keyboard shortcuts](../chat/keyboard.md).

```sh
# Start chat with a specific model
ripple chat --model LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16

# Resume most recent session for this project
ripple chat --resume

# Resume a specific session
ripple chat --resume 550e8400-e29b-41d4-a716-446655440000

# Chat in failover sandbox mode with transcript logging
ripple chat --sandbox failover --log ./logs/
```

---

## `ripple run`

```text
ripple run <scenarios> [--out <dir>] [CommonRunOptions]
```

Runs the scenario harness headlessly. See [Scenario harness](../scenarios.md) for the full
scenario file format and output schema.

| Argument / Flag | Description |
|---|---|
| `<scenarios>` | Path to a `.json` scenario file, or a directory of `.json` files. Required. |
| `--out <dir>` | Output directory for traces and `manifest.json`. Default: `deepagent-runs/latest/`. |

```sh
# Run a single scenario
ripple run scenarios/summarize.json

# Run all scenarios in a directory, custom output path
ripple run scenarios/ --out runs/2026-06-23/

# Run with auto-download and a custom sandbox image
ripple run scenarios/ --yes --sandbox-image ghcr.io/myorg/my-image:latest
```

Output files:

- `<id>.jsonl` - full agent trace per scenario
- `manifest.json` - observed vs. expected signatures, pass/fail

---

## `ripple mcp`

```text
ripple mcp [subcommand]
```

Manage MCP server configuration from the command line. See [MCP servers](../mcp.md) for full
configuration documentation.

!!! info
    Most MCP interaction happens inside `ripple chat` via the `/mcp` slash command (inspect
    servers, sign in, log out). The `ripple mcp` subcommand is for configuration management
    outside of a session.

---

## `ripple model`

```text
ripple model <subcommand> [args]
ripple models <subcommand> [args]     (alias)
```

Download and manage local MLX models. See [Local MLX models](../models/local.md) for details.

### Subcommands

| Subcommand | Aliases | Description |
|---|---|---|
| `list` | `ls` | List all models currently in the local Hugging Face cache (`~/.cache/huggingface/hub/`). |
| `pull <ids...>` | `download`, `get` | Download one or more models by Hugging Face id. Also accepts variant names, the keyword `default` (downloads the recommended default model), or `all`. |
| `rm <ids...>` | `remove`, `delete` | Remove one or more models from the local cache. |

```sh
# List downloaded models
ripple model list

# Download a specific model
ripple model pull LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16

# Download the default model
ripple model pull default

# Download all available models
ripple model pull all

# Remove a model
ripple model rm LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16

# Aliases work identically
ripple models ls
ripple models download LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
ripple models delete LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
```

---

## See also

- [Slash command reference](slash-commands.md)
- [MCP servers](../mcp.md)
- [Sandbox & shell](../sandbox.md)
- [Scenario harness](../scenarios.md)
- [Local MLX models](../models/local.md)
- [Configuration](../config/index.md)
- [Approvals & permission modes](../chat/approvals.md)
