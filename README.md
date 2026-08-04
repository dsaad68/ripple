<p align="center">
  <img src="docs/assets/images/ripple-logo.png" width="140" alt="Ripple">
</p>

<h1 align="center">Ripple</h1>

<p align="center">
  <a href="https://ripple.verybad.engineer"><img src="https://img.shields.io/badge/docs-ripple.verybad.engineer-0ea5e9?style=flat-square" alt="Docs"></a>
  <img src="https://img.shields.io/badge/Swift-6.1%2B-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.1+">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-555555?style=flat-square&logo=apple&logoColor=white" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/License-MIT-22c55e?style=flat-square" alt="MIT">
</p>

<p align="center">
  An on-device coding agent for macOS, a Claude Code-style terminal CLI that runs
  <a href="https://huggingface.co/LiquidAI">LFM2.5</a> models locally on Apple Silicon via MLX,
  with an interactive REPL, a headless mode, and a scenario harness.
  Built on <a href="https://github.com/dsaad68/deepagents-swift">DeepAgents</a>.
</p>

---

## Commands

```
ripple                     interactive deep-agent REPL (no subcommand needed)
ripple -p "..."            one-shot, non-interactive run (machine-readable output)
ripple run <scenarios>     headless TOML/JSON scenario harness
ripple mcp                 manage MCP servers
ripple model               download / manage local models
ripple --version           print the ripple and DeepAgents-swift versions
ripple --help              full usage and project links
```

Just run `ripple` to start the interactive REPL - no subcommand needed (`ripple chat` is the
explicit equivalent). Pipe text on stdin (`echo "..." | ripple`) for a one-shot run.

## Requirements

- macOS 26+ (Tahoe), Apple Silicon (arm64)
- Xcode 26+ only if you build from source (the prebuilt `brew install dsaad68/tap/ripple` needs no Xcode)

## Install

With Homebrew (prebuilt binary, no Xcode needed):

```sh
brew install dsaad68/tap/ripple
```

Or build from source from a clone (needs Xcode 26+, which is the only build system that co-locates
MLX's `default.metallib` beside the binary):

```sh
brew install --HEAD ./Formula/ripple.rb
```

Upgrade later with `brew upgrade ripple`.

Models come from your local Hugging Face cache; pre-fetch a planner first, e.g.:

```sh
hf download LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
```

## Docs

- Ripple: [ripple.verybad.engineer](https://ripple.verybad.engineer)
- DeepAgents: [deepagents-swift.verybad.engineer](https://deepagents-swift.verybad.engineer)

## License

MIT. See `LICENSE`.
