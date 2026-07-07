# Changelog

All notable changes to the Ripple CLI are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Ripple is published in lockstep with `deepagents-swift`, so the two version numbers normally match.

## [0.3.0] - 2026-07-08

### Added

- **New on-device reasoning models** in the catalog, the `/model` picker, and `--model`:
  - **Ornith-1.0-9B** (`mlx-community/Ornith-1.0-9B-4bit` / `-8bit`) - plans with `<think>`
    reasoning and native tool calls, *and* sees images, so it appears in both the planner and
    vision pickers plus a new **DeepAgent (Ornith)** preset that uses it for both roles.
  - **Qwen3.6** (`mlx-community/Qwen3.6-27B-OptiQ-4bit` ~20 GB, `Qwen3.6-35B-A3B-OptiQ-4bit`
    MoE ~24.7 GB) - the strongest local planners in the catalog; text-only.
  - **Gemma 4 E4B** (`mlx-community/gemma-4-e4b-it-8bit` ~9 GB, `gemma-4-e4b-it-OptiQ-4bit`
    ~7.5 GB) - reasons in Gemma's thought channel with native tool calls; a new
    **DeepAgent (Gemma 4)** preset pairs it with the LFM2.5 VLM for vision.
  All run with their model cards' recommended sampling and a 40k on-device context window.
- **Prefill cache.** The agent prompt's computed state is reused across rounds, queries, and now
  *processes* - the base snapshot persists to disk, so a fresh `ripple` launch resumes it instead
  of re-prefilling the ~10k-token system+tools prompt (cold prompt processing ~14 s → ~0.2 s
  measured on Ornith 9B). Toggleable in `/config` ▸ Capabilities as **Prefill cache**
  (`prefixKVCache` in `settings.json`), honored by the REPL and headless runs.
- **Apple Notes tools.** The agent can list, read, create, and update Apple Notes
  (`apple_notes` toolset; writes are approval-gated, reads are not).
- **`/tools` browser** - a two-level browser of the agent's tools grouped by toolset, with each
  tool's description, parameters, and a `[needs approval]` badge.
- **`ripple` works in its launch directory.** Filesystem tools and the `@` picker root at the
  directory ripple was started in, and each session's transcript is written to
  `.ripple/sessions/` inside it (`--log <dir>` overrides).
- **Bordered three-choice approval prompt** (Approve / Reject / Always allow, arrow keys or
  `a`/`r`/`A`) and a gradient ASCII-art launch wordmark.

### Fixed

- **Failures are never silent.** A turn that dies mid-generation ends with a red
  `✗ turn failed - <reason>` line under whatever streamed (the loader's real reason included),
  instead of an empty answer. A broken planner no longer keeps `ripple chat` from starting:
  launch falls back to the default model when it's on disk, or opens on the chosen model anyway
  and retries on the first message - either way a transcript note says what happened. A failed
  `/model` switch notes the failure and keeps the current planner. Headless runs print the
  loader's recorded reason and exit non-zero.
- **Download progress is real.** Multi-GB pulls no longer sit at 0% (the hub's Xet transport
  reports no incremental progress; the bar now blends live in-flight bytes), the `/model` Local
  tab draws its progress bar inside the panel (it was hidden behind the menu) with `esc` to
  cancel, and a cold (re)load names its phase - `loading <model> into memory…`,
  `prefilling the prompt…` - instead of a bare "working…".
- **The tokens/sec readout measures real decode speed** - every generated token (reasoning +
  answer) over active decoding time, excluding prefill, tool runs, and round transitions.
- **A turn renders in the order it happened.** Reasoning / tool / plan / answer blocks keep
  their streamed sequence instead of being grouped by type.
- **`ask_user` (and every tool with nested array/object parameters) works on the Ornith,
  Qwen3.6, and Gemma 4 planners** - tool schemas are now passed into generation so nested
  values arrive typed.

## [0.2.5] - 2026-06-29

### Added

- **AWS Bedrock API keys (bearer-token auth).** A `bedrock` model can now authenticate with an Amazon
  Bedrock API key instead of AWS SigV4 credentials. Put the token in the model's `apiKey` field (e.g.
  `"$AWS_BEARER_TOKEN_BEDROCK"`) and set a `baseURL`; requests are then sent with
  `Authorization: Bearer <token>`. Resolution order is `apiKey` -> the `AWS_BEARER_TOKEN_BEDROCK`
  environment variable -> SigV4 access-key credentials, so existing SigV4 setups keep working
  unchanged. See the Bedrock section of the remote-models docs for both configurations.

## [0.2.4] - 2026-06-26

### Fixed

- **Up/Down arrows move between the lines of a multi-line prompt.** In the `ripple chat` input box the
  arrow keys now move the caret one visual row up or down -- across hard newlines and soft-wrapped rows
  alike -- and fall back to prompt-history recall only at the top/bottom edge (the familiar shell
  behavior). The column is preserved per press. Single-line and empty input keep history recall, and
  the ask_user card's choice navigation is unchanged.

### Packaging

- **Homebrew tap.** `ripple` is now installable as a prebuilt Apple Silicon binary -- no Xcode
  required:
  ```sh
  brew install dsaad68/tap/ripple
  ```
  Each release is built on a self-hosted runner, attached to the GitHub Release as a `macos-arm64`
  artifact, and the tap formula is bumped automatically. Building from source via
  `brew install --HEAD ./Formula/ripple.rb` still works.

## [0.2.3] - 2026-06-26

### Added

- **OAuth auto-detection for HTTP MCP servers.** A plain `{"type":"http","url":"..."}` entry that
  needs authentication is now discovered from its `401` challenge at connect time (the way Claude Code
  does it) -- no `"oauth": {}` key required. In `/mcp` such a server is flagged "press r to sign in",
  and `r` or Enter drives the browser sign-in flow. An explicit `"oauth": {}` is still supported as an
  override (force the flow, or pin the authorization server via `authServerMetadataUrl`). A server
  with a static `Authorization` header is left as header auth and never offered the flow.
- **`ripple mcp login <name>` works on any HTTP server**, not just ones declared `oauth` -- it forces
  the sign-in flow and caches the token in the Keychain.

### Fixed

- **`r` (re-auth) in `/mcp` did nothing for servers not declared `oauth`.** The footer always
  advertised `r (re)auth` / `x log out`, but the key handler ignored those keys unless the highlighted
  server used `oauth`, so the keystroke leaked into the input instead. The subtitle, footer, launch
  banner nudge, and the `r` / `x` / Enter keys are now all driven by the server's actual auth state.

### Changed

- **`ripple mcp list --probe`** reports a `401` as "not signed in" (with the `mcp login` hint) instead
  of a raw "unreachable" error, and the `mcp list` auth label no longer mislabels a plain HTTP server
  (no `oauth` key, no `Authorization` header) as "headers".

## [0.2.2]

- Added `ripple --version` (prints the ripple and DeepAgents-swift versions) plus version / About
  surfaces with documentation links.

[0.3.0]: https://github.com/dsaad68/ripple/releases/tag/0.3.0
[0.2.4]: https://github.com/dsaad68/ripple/releases/tag/0.2.4
[0.2.3]: https://github.com/dsaad68/ripple/releases/tag/0.2.3
[0.2.2]: https://github.com/dsaad68/ripple/releases/tag/0.2.2
