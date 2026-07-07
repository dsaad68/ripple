# Scenario harness

`ripple run` is a headless batch harness for running agents against a fixed set of inputs and
checking their outputs against expected signatures. It is designed for regression testing,
capability benchmarking, and automated evaluation pipelines - situations where you need
reproducible, deterministic runs without an interactive session.

---

## Basic usage

```sh
ripple run <scenarios> [--out <dir>]
```

`<scenarios>` is either:

- A single `.json` scenario file, or
- A directory of `.json` files (all are run in sequence).

`--out` sets the output directory (default: `deepagent-runs/latest/`).

```sh
# Run a single scenario
ripple run scenarios/summarize-code.json

# Run all scenarios in a directory
ripple run scenarios/ --out runs/2026-06-23/

# Run with a specific model
ripple run scenarios/ --model LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
```

!!! note "Model download"
    If the scenario's model is not in the local Hugging Face cache, `ripple run` prints a hint
    and bails. Pass `--yes` (`--download`) to auto-download without prompting.

---

## Scenario file format

Scenario files are JSON. In practice, they are **authored as TOML** and converted to JSON by a
wrapper script - TOML is easier to write for multiline strings and nested structures. The JSON
schema is the source of truth.

### Complete schema

```json
{
  "id": "scenario-name",
  "agent": {
    "model": "LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16",
    "system_prompt": "registry-key-or-inline-text",
    "middleware": ["screenshot", "clipboard"],
    "tools": ["calculator"],
    "include_filesystem": false,
    "include_general_purpose": false,
    "max_iterations": 24,
    "backend": "memory",
    "approvals": "auto-approve",
    "subagents": [
      {
        "name": "researcher",
        "description": "Searches for and summarizes information",
        "model": "LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16",
        "system_prompt": "You are a research assistant...",
        "tools": ["web_search"],
        "middleware": [],
        "max_iterations": 12
      }
    ]
  },
  "prompts": {
    "turns": [
      "First user message",
      "Second user message"
    ]
  },
  "fixtures": {
    "clipboard": "seed text for the clipboard",
    "windows": [
      { "name": "App - Document Title", "png": "/abs/path/to/window.png" }
    ],
    "screen": "/abs/path/to/fullscreen.png"
  },
  "expect": {
    "signature_name": true
  }
}
```

---

## Field reference

### Top level

| Field | Type | Description |
|---|---|---|
| `id` | string | Unique identifier for the scenario. Used in trace filenames and the manifest. |
| `agent` | object | Agent configuration (see below). |
| `prompts` | object | The conversation to replay. |
| `fixtures` | object | Deterministic input seeds (optional). |
| `expect` | object | Expected output signatures to check (optional). |

### `agent`

| Field | Type | Description |
|---|---|---|
| `model` | string | Hugging Face model id or registered remote model name. |
| `system_prompt` | string | A registry key (looked up from the prompt registry) or inline system prompt text. |
| `middleware` | string[] | Capability middleware to enable (e.g. `"screenshot"`, `"clipboard"`). |
| `tools` | string[] | Named tools to add to the agent. |
| `include_filesystem` | bool | Whether to include filesystem tools (`read_file`, `write_file`, etc.). |
| `include_general_purpose` | bool | Whether to include general-purpose tools. |
| `max_iterations` | int | Maximum agent loop iterations before the run is terminated. |
| `backend` | `"memory"` \| `"local"` | Message store: `memory` (in-process only) or `local` (persisted to disk). |
| `approvals` | `"auto-approve"` \| `"auto-reject"` | Approval policy for all tool calls. `auto-approve` lets the agent run tools without prompting; `auto-reject` blocks every tool call. |
| `subagents` | object[] | Subagent definitions the planner can delegate to (see below). |

### `agent.subagents[]`

| Field | Type | Description |
|---|---|---|
| `name` | string | Identifier used when the planner delegates to this subagent. |
| `description` | string | Natural-language description of what this subagent does. |
| `model` | string | Optional model override. Inherits the planner model if omitted. |
| `system_prompt` | string | System prompt for this subagent. |
| `tools` | string[] | Tools available to this subagent. |
| `middleware` | string[] | Middleware enabled for this subagent. |
| `max_iterations` | int | Maximum iterations for this subagent's loop. |

### `prompts`

| Field | Type | Description |
|---|---|---|
| `turns` | string[] | Ordered list of user messages. Each string is delivered as a separate turn, in sequence. |

### `fixtures`

Fixtures seed inputs that would otherwise require live system state. They make runs deterministic
without needing Screen Recording permission or a live application.

| Field | Type | Description |
|---|---|---|
| `clipboard` | string | Text pre-loaded into the clipboard before the run. |
| `windows` | object[] | Fake window screenshots: `{ "name": "App - Title", "png": "/abs/path/window.png" }`. |
| `screen` | string | Absolute path to a full-screen PNG used instead of a live screenshot. |

### `expect`

A flat object of signature name to boolean. After the run, Ripple checks whether each named
signature was observed in the trace and records pass/fail in `manifest.json`.

```json
"expect": {
  "tool_called_write_file": true,
  "response_contains_summary": true
}
```

---

## Output

For each run, Ripple writes to the output directory (default `deepagent-runs/latest/`):

| File | Contents |
|---|---|
| `<id>.jsonl` | Full agent trace for the scenario: every message, tool call, and tool result. |
| `manifest.json` | Summary: one entry per scenario with `observed` (what actually happened) vs `expected` (from the `expect` field), plus pass/fail per signature. |

```text
deepagent-runs/latest/
  summarize-code.jsonl
  extract-tables.jsonl
  manifest.json
```

Inspect a trace to debug unexpected behavior:

```sh
# Pretty-print the first scenario's trace
cat deepagent-runs/latest/summarize-code.jsonl | jq .
```

---

## Authoring in TOML

Because JSON is verbose for multiline strings and nested configs, scenario files are commonly
authored as TOML and converted to JSON:

```toml
id = "summarize-code"

[agent]
model = "LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16"
system_prompt = """
You are a code reviewer. Summarize the key changes in the provided diff.
"""
include_filesystem = false
include_general_purpose = false
max_iterations = 8
backend = "memory"
approvals = "auto-approve"

[prompts]
turns = [
  "Summarize this diff: ...",
]

[expect]
response_contains_summary = true
```

Convert with any TOML-to-JSON tool before passing to `ripple run`:

```sh
python3 -c "import tomllib, json, sys; print(json.dumps(tomllib.loads(sys.stdin.read()), indent=2))" \
  < scenarios/summarize-code.toml > scenarios/summarize-code.json
```

---

## Memory management

Ripple calls `MLX.Memory.clearCache()` between scenario runs to release GPU memory. This keeps
multi-scenario batches from accumulating metal allocations and improves stability on long runs.

---

## Complete example

A scenario that tests whether the agent correctly writes a summary file given a code snippet:

```json
{
  "id": "write-summary",
  "agent": {
    "model": "LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16",
    "system_prompt": "You are a concise technical writer. When given code, write a one-paragraph summary to summary.md.",
    "include_filesystem": true,
    "include_general_purpose": false,
    "max_iterations": 6,
    "backend": "memory",
    "approvals": "auto-approve"
  },
  "prompts": {
    "turns": [
      "Write a summary of this function:\n\nfunc add(_ a: Int, _ b: Int) -> Int { a + b }"
    ]
  },
  "expect": {
    "tool_called_write_file": true
  }
}
```

Run it:

```sh
ripple run scenarios/write-summary.json --out runs/test-1/
cat runs/test-1/manifest.json
```

Expected manifest output:

```json
[
  {
    "id": "write-summary",
    "observed": ["tool_called_write_file"],
    "expected": { "tool_called_write_file": true },
    "passed": true
  }
]
```

---

## See also

- [Command reference](reference/commands.md) - `ripple run` flags
- [Models overview](models/index.md) - available models and download
- [Configuration](config/index.md) - `settings.json`, tool policy
