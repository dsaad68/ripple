# Changelog

All notable changes to the Ripple CLI are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Ripple is published in lockstep with `deepagents-swift`, so the two version numbers normally match.

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

[0.2.4]: https://github.com/dsaad68/ripple/releases/tag/0.2.4
[0.2.3]: https://github.com/dsaad68/ripple/releases/tag/0.2.3
[0.2.2]: https://github.com/dsaad68/ripple/releases/tag/0.2.2
