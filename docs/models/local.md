# Local MLX models

Ripple can run any MLX-quantized model from Hugging Face directly on your Mac. All inference
happens on-device via Apple Silicon's unified memory architecture - no network call, no API key,
no token cost.

---

## Model id format

Local model ids normally follow the Hugging Face `<provider>/<name>` convention exactly:

```text
LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
LiquidAI/LFM2.5-8B-A1B-MLX-8bit
```

A few conversions publish every precision as a subfolder of a *single* repo instead of one repo per
precision. Those ids carry a third component naming the precision:

```text
LiquidAI/LFM2.5-2.6B-MLX/mxfp4
LiquidAI/LFM2.5-2.6B-MLX/bf16
```

Each precision is selected, downloaded, and removed independently, exactly like any other model -
Ripple downloads only that subfolder, and removing one leaves its siblings intact.

The same id is used everywhere: `--model`, the `/model` picker, and `ripple model pull`.

---

## Supported model families

Ripple ships a built-in catalog of on-device models:

| Family | Kind | Notes |
|---|---|---|
| LiquidAI LFM2.5 (Instruct / Thinking / 8B-A1B MoE) | Language | Tool-using planners; the Thinking models reason in `<think>` blocks |
| `LiquidAI/LFM2.5-2.6B-MLX/<precision>` | Language | General-purpose 2.69B planner in four precisions - `mxfp4` (~1.6 GB), `mxfp8` (~2.8 GB), `8bit` (~2.9 GB), `bf16` (~5.4 GB). Reasons in `<think>` blocks; the only catalog model run at its full 128k context |
| LiquidAI LFM2.5-VL | Vision | Image-capable; back the deep-agent vision subagent |
| `mlx-community/Ornith-1.0-9B-4bit` / `-8bit` | Reasoning + Vision | A single qwen3_5 model that both plans (with `<think>` reasoning and tool calls) and sees images |
| `mlx-community/Qwen3.6-27B-OptiQ-4bit` | Reasoning | Qwen3.6 dense, text-only planner (~20 GB) |
| `mlx-community/Qwen3.6-35B-A3B-OptiQ-4bit` | Reasoning | Qwen3.6 MoE (3B active), text-only; strongest local planner in the catalog (~24.7 GB) |
| `mlx-community/gemma-4-e4b-it-8bit` | Reasoning | Gemma 4 E4B (4.5B effective), plans with a thought channel and native tool calls (~9 GB) |
| `mlx-community/gemma-4-e4b-it-OptiQ-4bit` | Reasoning | Gemma 4 E4B mixed-precision OptiQ quant, text-only planner (~7.5 GB) |

[Ornith-1.0-9B](https://huggingface.co/deepreinforce-ai/Ornith-1.0-9B), the
[Qwen3.6](https://huggingface.co/Qwen/Qwen3.6-27B) models, and
[Gemma 4 E4B](https://huggingface.co/google/gemma-4-E4B-it) are reasoning models: each turn opens
with a reasoning block (`<think>…</think>` for the qwen family, a Gemma thought channel for
Gemma 4) that Ripple surfaces as separate reasoning, and they emit structured tool calls that the
runtime parses automatically. Ornith also sees images, so it appears in **both** the main-agent
(planner) and vision pickers (the **DeepAgent (Ornith)** preset uses it for both roles at once).
The Qwen3.6 and Gemma 4 models are text-only planners: the OptiQ conversions ship no image
processor configs, and Gemma 4's vision path is blocked on an upstream mlx-swift-lm loader bug
(the **DeepAgent (Gemma 4)** preset pairs it with the LFM2.5 VLM for vision until that fix
ships). All run with their card-recommended sampling: Ornith temperature 0.6 / top-p 0.95 /
top-k 20; Qwen3.6 temperature 1.0 / top-p 0.95 / top-k 20, plus presence penalty 1.5 on the
35B-A3B; Gemma 4 temperature 1.0 / top-p 0.95 / top-k 64. Mind the sizes - Ornith is ~5-10 GB,
Gemma 4 ~7.5-9 GB, the Qwen3.6 quants ~20-25 GB on disk and in memory.

---

## Hugging Face cache

Downloaded models land in the standard Hugging Face hub cache:

```text
~/.cache/huggingface/hub/
```

Ripple does not maintain its own model store. If you already have a model cached (by `huggingface_hub`,
the Python `transformers` library, or `hf` CLI), Ripple will find and use it without re-downloading.

---

## Managing models with `ripple model`

The `ripple model` sub-command (alias `ripple models`) covers listing, downloading, and removing
local MLX models.

### List downloaded models

```sh
ripple model list
ripple model ls          # alias
```

Prints every model currently in the Hugging Face cache that Ripple recognizes, along with its
disk footprint.

### Download models

```sh
ripple model pull LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
ripple model download <id>   # alias
ripple model get <id>        # alias
```

You can pass multiple ids in one command:

```sh
ripple model pull LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16 LiquidAI/LFM2.5-2.6B-MLX/mxfp4
```

For a subfolder-packaged repo, pull the precision you want - not the bare repo, which is not a model
id and will be rejected:

```sh
ripple model pull LiquidAI/LFM2.5-2.6B-MLX/mxfp4   # ~1.6 GB, just this precision
ripple model pull LiquidAI/LFM2.5-2.6B-MLX         # error: unknown model
```

Two special variant names are also accepted:

| Variant | Meaning |
|---|---|
| `default` | The default DeepAgent preset's models (currently LFM2.5 8B-A1B plus the VL 1.6B vision model) |
| `all` | Every model in Ripple's built-in catalog |

```sh
ripple model pull default     # download the recommended model
ripple model pull all         # download the full catalog
```

### Remove models

```sh
ripple model rm LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
ripple model remove <id>      # alias
ripple model delete <id>      # alias
```

This removes the model from `~/.cache/huggingface/hub/`. The id must match exactly.

For a subfolder-packaged repo, removing one precision removes **only** that precision: the shared
repo directory and any sibling precisions you still have stay in place and stay loadable. The disk
space is genuinely reclaimed - files that precision alone referenced are deleted, and files it
shared with a sibling (the tokenizer, for instance) are kept. Removing the last precision drops the
repo directory entirely.

---

## The `/model` Local tab

Inside an interactive session, type `/model` and switch to the **Local** tab. It shows the
Hugging Face catalog of supported MLX models with their size and download status. Press **enter**
to download the highlighted model and **x** to remove it - both without leaving the chat. A live
progress bar is drawn at the top of the tab (and the row being fetched shows its percentage);
**esc** cancels the download, and partial files resume on the next pull. Once complete the model
becomes immediately selectable in the **Select** tab.

---

## Download-on-run behavior

Ripple does **not** silently download a model when you start a session or pass `--model`. The
behavior depends on whether you are running interactively or headlessly:

**Interactive (`ripple chat` or bare `ripple`):** Ripple detects the missing model before the
session starts and prompts:

```text
Model LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16 is not downloaded. Download now? [y/N]
```

Answer `y` to download, `n` to abort. Pass `--yes` (or `--download`) to skip the prompt and
download automatically:

```sh
ripple --model LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16 --yes
```

**Headless (`ripple -p "..."`):** If the model is missing and `--yes` is not set, Ripple prints
a hint and exits with a non-zero status. Headless runs are designed for scripting and pipelines
where an unexpected interactive prompt would hang. Pass `--yes` to allow the download:

```sh
ripple -p "summarize README.md" --model LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16 --yes
```

!!! warning
    In CI or other non-interactive environments always pre-fetch models before running Ripple
    (see below), or pass `--yes` explicitly. Without `--yes` a headless run against a missing
    model will fail immediately.

---

## Load-failure behavior

A model that is on disk can still fail to load - a half-fetched snapshot, an unsupported
architecture, a corrupted file. `ripple chat` degrades instead of refusing to start:

- If the **default planner** is a different model that is already on disk, it takes over and the
  session opens with a transcript note naming the model that failed and why. Switch back (or to
  anything else) with `/model` once the problem is fixed.
- Otherwise the session opens on the **chosen model anyway**: sending a message retries its load,
  and a failure is reported as a red `✗ turn failed - <reason>` line in the transcript rather
  than a silent empty answer. Pick another model with `/model` at any point.

The same applies mid-session: a planner that fails to reload after an idle-unload reports into
the transcript, and a `/model` switch whose target cannot be built leaves a note and keeps the
current planner running. Headless runs (`ripple -p`) print the loader's recorded reason and exit
non-zero instead.

---

## Pre-fetching with `hf download`

For scripts or CI pipelines, pre-fetch a model with the Hugging Face CLI so it is already in
the cache when Ripple starts:

```sh
hf download LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
```

Install the CLI with `pip install huggingface_hub` or `uv tool install huggingface_hub` if you
do not already have it. The model lands in `~/.cache/huggingface/hub/` and Ripple will use it
without prompting.

---

## Requirements

- Apple Silicon (arm64) - MLX does not run on Intel Macs.
- macOS 26 (Tahoe) or later.
- Sufficient RAM: the 1.2B bf16 model needs roughly 2-3 GB; the 2.6B model 2-6 GB depending on
  precision (`mxfp4` is the cheapest); the 8B-A1B model 10-16 GB.

See [Installation](../getting-started/installation.md) for the full setup checklist.
