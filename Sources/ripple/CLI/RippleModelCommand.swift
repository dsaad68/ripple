import Darwin
import DeepAgents
import DeepAgentsMLX
import Foundation

/// `ripple model <list|pull|rm>` - download and manage the on-device MLX models from the command
/// line, so ripple no longer depends on the Mispher app to populate the Hugging Face cache. A thin
/// front-end over ``ModelCache`` (itself a facade on ``MlxModelLoader``'s cache helpers): `list`
/// shows the catalog with sizes + downloaded state, `pull` fetches one or more models behind a
/// progress bar, `rm` deletes them. A `pull`/`rm` argument may be a model id, a ``DeepAgentVariant``
/// (expands to its planner + vision models), `default`, or `all`.
@MainActor
enum RippleModelCommand {
    static func run(_ args: [String]) async {
        let sub = args.first ?? "list"
        let rest = Array(args.dropFirst())
        switch sub {
        case "list", "ls": list(rest)
        case "pull", "download", "get": await pull(rest)
        case "rm", "remove", "delete": rm(rest)
        case "-h", "--help", "help": usageModel(nil)
        default: usageModel("unknown model subcommand: \(sub)")
        }
    }

    // MARK: - list

    private static func list(_: [String]) {
        let defaults = Set(defaultVariant.modelIDs)
        out(Paint.fg(245, "Local models") + Paint.fg(240, "  (✓ downloaded · ○ not yet)"))
        for model in MlxModel.catalog {
            let mark = ModelCache.isDownloaded(model.id) ? Paint.fg(114, "✓") : Paint.fg(240, "○")
            var tags = [model.detail, model.sizeLabel]
            if defaults.contains(model.id) { tags.append("default") }
            out("  " + mark + " " + Paint.bold(model.displayName)
                + Paint.fg(240, "  ·  " + tags.joined(separator: "  ·  ")))
            out("    " + Paint.fg(244, model.id))
        }

        // User-registered OpenAI-compatible models, if any (from `.ripple/settings.json`). These are
        // remote - nothing to download - so they carry no on-disk state, just how to select one.
        let remote = RippleModelConfig.loadModels(
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        )
        if !remote.isEmpty {
            out("")
            out(Paint.fg(245, "Remote models") + Paint.fg(240, "  (OpenAI-compatible · from .ripple/settings.json)"))
            for config in remote {
                let tags = remoteTags(config)
                out("  " + Paint.fg(75, "◆") + " " + Paint.bold(config.name)
                    + Paint.fg(240, "  ·  " + tags.joined(separator: "  ·  ")))
                out("    " + Paint.fg(244, "ripple chat --model \(config.name)"))
            }
        }

        out("")
        out(Paint.fg(240, "fetch one with: ripple model pull <id|default|all>"))
    }

    /// The dimmed tags shown after a remote model's name in `model list`: its upstream model id and
    /// host, plus the `vision` / `reasoning` capability flags when enabled.
    nonisolated static func remoteTags(_ config: OpenAIModelConfig) -> [String] {
        var tags = [config.model, config.host]
        if config.vision { tags.append("vision") }
        if config.reasoning { tags.append("reasoning") }
        return tags
    }

    // MARK: - pull

    private static func pull(_ args: [String]) async {
        let force = args.contains("--force")
        let tokens = positionals(args)
        guard !tokens.isEmpty else {
            usageModel("model pull: name a model id, a variant, `default`, or `all`."); return
        }
        var ids: [String] = []
        for token in tokens {
            guard let resolved = resolve(token) else {
                err("model pull: unknown model '\(token)'."); err(knownHint()); return
            }
            for id in resolved where !ids.contains(id) { ids.append(id) }
        }
        var failed = false
        for id in ids {
            let label = MlxModel.catalog.first { $0.id == id }?.shortName ?? id
            if ModelCache.isDownloaded(id), !force {
                out(Paint.fg(114, "✓") + " " + label + Paint.fg(240, " already downloaded"))
                continue
            }
            var reason: String?
            let ok = await CLIProgressBar.run(label: label, verb: "downloading", doneVerb: "downloaded") { progress in
                do {
                    try await ModelCache.download(id, progress: progress)
                    return true
                } catch {
                    reason = error.localizedDescription
                    return false
                }
            }
            if !ok { failed = true; if let reason { err("  " + Paint.fg(240, reason)) } }
        }
        if failed { err("model pull: one or more downloads failed.") }
    }

    // MARK: - rm

    private static func rm(_ args: [String]) {
        guard let token = positionals(args).first, !token.isEmpty else {
            err("model rm: name a model id (or a variant / `all`)."); return
        }
        guard let ids = resolve(token) else {
            err("model rm: unknown model '\(token)'."); err(knownHint()); return
        }
        let present = ids.filter { ModelCache.isDownloaded($0) }
        guard !present.isEmpty else {
            out(Paint.fg(244, "nothing to remove - " + (ids.count == 1 ? "it isn't" : "none are") + " downloaded."))
            return
        }
        if !args.contains("--yes") {
            let names = present.map { id in MlxModel.catalog.first { $0.id == id }?.shortName ?? id }
            guard isatty(STDIN_FILENO) != 0 else {
                // No tty to confirm at: refuse rather than silently delete (so a piped/scripted
                // `model rm` can't wipe weights without an explicit opt-in).
                err("model rm: re-run with --yes to remove " + names.joined(separator: ", ") + " (no tty to confirm).")
                return
            }
            write("remove " + names.joined(separator: ", ") + "? [y/N] ")
            let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else { out(Paint.fg(244, "cancelled.")); return }
        }
        for id in present {
            ModelCache.remove(id)
            let label = MlxModel.catalog.first { $0.id == id }?.shortName ?? id
            out(Paint.fg(114, "✓") + " removed " + label)
        }
    }

    // MARK: - Resolution

    /// Expand a `pull`/`rm` token into the catalog ids it names: an exact model id, a
    /// ``DeepAgentVariant`` id or label (-> its planner + vision ids), `default` (-> the default
    /// variant), or `all` (-> the whole catalog). Nil if nothing matches.
    static func resolve(_ token: String) -> [String]? {
        let lower = token.lowercased()
        if lower == "all" { return MlxModel.catalog.map(\.id) }
        if lower == "default" { return defaultVariant.modelIDs }
        if MlxModel.catalog.contains(where: { $0.id == token }) { return [token] }
        if let variant = DeepAgentVariant.all.first(where: {
            $0.id == token || $0.id.lowercased() == lower || $0.label.lowercased() == lower
        }) { return variant.modelIDs }
        return nil
    }

    /// The non-flag tokens (model commands have no value-taking flags, so any `-`-prefixed token is
    /// a flag like `--force` / `--yes`).
    static func positionals(_ args: [String]) -> [String] {
        args.filter { !$0.hasPrefix("-") }
    }

    private static var defaultVariant: DeepAgentVariant {
        DeepAgentVariant.all.first { $0.id == "mispher.deepagent" } ?? DeepAgentVariant.all[0]
    }

    private static func knownHint() -> String {
        Paint.fg(240, "try: default, all, " + DeepAgentVariant.all.map(\.id).joined(separator: ", ")
            + " - or any id from `ripple model list`.")
    }

    // MARK: - Output

    private static func out(_ message: String) { print(message) }

    private static func err(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Stderr, no trailing newline - for an inline `[y/N]` prompt before a `readLine()`.
    private static func write(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static func usageModel(_ message: String?) {
        if let message { err("error: \(message)") }
        err("""
        usage:
          ripple model list                                      the catalog with sizes + downloaded state
          ripple model pull <id|variant|default|all> [--force]   download model(s) with a progress bar
          ripple model rm   <id|variant|all> [--yes]             delete model(s) from the local cache
        """)
    }
}
