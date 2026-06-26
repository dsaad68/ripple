# Installation

Ripple installs with Homebrew. The quickest path is the prebuilt tap - a signed Apple Silicon binary, no Xcode required. If you'd rather build locally (or hack on ripple), you can also build from source from a clone.

## Requirements

| Requirement | Detail |
|---|---|
| macOS | 26+ (Tahoe) |
| Architecture | Apple Silicon (arm64) - required for MLX on-device inference |
| Xcode | 26+ - must be installed and active (`xcode-select`) |
| Homebrew | Any recent version |
| `hf` CLI | Optional, for pre-fetching models from Hugging Face |

!!! warning "Intel Macs are not supported"
    MLX targets Apple Silicon exclusively. Ripple can run remote models on Intel if you build it, but the on-device inference path is arm64-only. The Homebrew formula will refuse to install on x86_64.

## Install with Homebrew (recommended)

Install the prebuilt binary from the tap - no clone, no Xcode:

```sh
brew install dsaad68/tap/ripple
```

This pulls the signed `macos-arm64` build attached to the latest [release](https://github.com/dsaad68/ripple/releases) and puts `ripple` on your `PATH`. Upgrade later with `brew upgrade ripple`.

Then skip ahead to [Pre-fetch a planner model](#step-3-pre-fetch-a-planner-model).

## Build from source (alternative)

Prefer to build locally, or want to hack on ripple? Install the `--HEAD` formula from a clone. This needs Xcode 26+ and drives `xcodebuild` rather than `swift build` - the only build system that emits `default.metallib` alongside the binary.

### Step 1 - Clone the repository

```sh
git clone https://github.com/dsaad68/ripple.git
cd ripple
```

### Step 2 - Install via Homebrew

Install the `--HEAD` formula from the local clone:

```sh
brew install --HEAD ./Formula/ripple.rb
```

Homebrew calls `xcodebuild` under the hood. The build typically takes 3-5 minutes the first time while Xcode resolves Swift packages and compiles the Metal shaders. Subsequent installs (after `brew reinstall`) are faster because the SPM cache is warm.

!!! tip "If the build fails inside Homebrew's sandbox"
    On some machines Homebrew's build sandbox blocks `xcodebuild`'s network access to the Swift Package Index. If that happens, set `HOMEBREW_NO_SANDBOX=1`:

    ```sh
    HOMEBREW_NO_SANDBOX=1 brew install --HEAD ./Formula/ripple.rb
    ```

    This disables Homebrew's process sandbox for this install only; it is safe.

The formula installs two things into Homebrew's `libexec` directory:

- The `ripple` binary and `*.bundle` resource files (Metal shaders, model configs)
- A launcher shim in `bin/ripple` that sets up the correct resource path before exec-ing the real binary

Both must stay co-located; do not move or symlink just the binary.

## Step 3 - Pre-fetch a planner model

Ripple does not auto-download a model on first launch - you supply one explicitly. The recommended starting model is LiquidAI's LFM2.5 1.2B instruct in MLX bf16 format:

```sh
hf download LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
```

This saves the weights to `~/.cache/huggingface/hub/`, which is where Ripple looks for local models. The download is roughly 1.2 GB.

If you do not have the `hf` CLI, install it with:

```sh
pip install huggingface_hub[cli]
# or
brew install huggingface-cli
```

You can also pull models via Ripple itself after installation:

```sh
ripple model pull LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
```

!!! note "Larger models"
    The 1.2B model runs comfortably on 16 GB unified memory. If you have 32 GB or more, the 8B variant (`LiquidAI/LFM2.5-8B-Instruct-MLX-bf16`) handles longer context and more complex reasoning tasks. See [Local MLX models](../models/local.md) for the full catalog and memory guidance.

## Step 4 - Apple Notes Automation permission

Ripple's Apple Notes tools use the macOS Automation APIs. The first time you run a task that touches Notes, macOS will prompt for permission. If you want to grant it proactively:

1. Open **System Settings > Privacy & Security > Automation**.
2. Find **ripple** (or **Terminal**, depending on how you launched it).
3. Enable the **Notes** checkbox.

You can skip this step and grant permission on demand when the prompt appears.

## Step 5 - Verify the installation

```sh
ripple --help
```

You should see the top-level usage showing `chat`, `run`, `mcp`, and `model` subcommands. To confirm the model loads correctly, run a quick one-shot:

```sh
ripple -p "Say hello" --model LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16 --yes
```

`--yes` tells Ripple to load the model without prompting. If you see a response, the Metal shaders and model weights are correctly wired up.

## Keeping Ripple up to date

If you installed from the tap:

```sh
brew upgrade ripple
```

If you built from source, after pulling new commits:

```sh
cd ripple
git pull
brew reinstall --HEAD ./Formula/ripple.rb
```

## Troubleshooting

??? note "xcodebuild: command not found"
    Xcode 26 must be installed from the App Store or the Apple Developer portal, not just the Command Line Tools package. After installing, run:
    ```sh
    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
    ```

??? note "ripple crashes immediately after install"
    The most common cause is the `default.metallib` not being found. Confirm the shim is in place:
    ```sh
    which ripple          # should point into Homebrew's bin/
    ripple --help         # should not crash
    ```
    If you installed by copying the raw binary rather than via the formula, the metallib is missing. Reinstall via `brew install --HEAD ./Formula/ripple.rb`.

??? note "Model not found"
    Ripple looks in `~/.cache/huggingface/hub/`. Run `ripple model list` to see what's cached, or `ripple model pull <id>` to download.

## Next steps

- [Quickstart](quickstart.md) - your first interactive session
- [Local MLX models](../models/local.md) - browse the model catalog, memory requirements, and variant naming
