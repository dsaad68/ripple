import Foundation

/// Project instructions for the deep agent, read from `AGENTS.md`, `CLAUDE.md`, and `RIPPLE.md`.
///
/// Loading starts at the working directory (the folder `ripple` was launched in) and walks **up to
/// and including the git repo root** - the first ancestor that holds a `.git` entry - reading every
/// level on the way, so a launch from a nested subfolder still picks up the project's top-level
/// guidance. When the working directory isn't inside a git repo, only the working directory itself is
/// read. Within one directory every present file is loaded (all three, in `AGENTS` -> `CLAUDE` ->
/// `RIPPLE` order); the merged text is fed into the planner's system prompt (see
/// ``RippleDeepAgent/make(textModel:visionModel:memory:approvalHandler:askUserHandler:messageLog:workingDirectory:policy:mcpTools:mcpApprovalDefaults:projectInstructions:)``)
/// and the loaded files are listed in the launch banner.
enum RippleInstructions {
    /// The instruction filenames read at each directory, in load order.
    static let fileNames = ["AGENTS.md", "CLAUDE.md", "RIPPLE.md"]

    /// One loaded instruction file: a short repo-root-relative `label` (for the banner) and its
    /// trimmed `contents` (for the system prompt).
    struct File: Equatable, Sendable {
        let label: String
        let contents: String
    }

    /// The instruction files found for a working directory, plus the banner labels and the
    /// system-prompt block derived from them.
    struct Loaded: Equatable, Sendable {
        /// The loaded files in system-prompt order: repo root first, working directory last (general
        /// -> specific, so a nested file's guidance reads after - and can override - the project-wide
        /// one).
        var files: [File]

        var isEmpty: Bool { files.isEmpty }

        /// The labels listed in the launch banner, in load order (repo root first).
        var labels: [String] { files.map(\.label) }

        /// The system-prompt block - each file under its label, general -> specific - or nil when no
        /// instruction files were found.
        var promptText: String? {
            guard !files.isEmpty else { return nil }
            let body = files.map { "### \($0.label)\n\($0.contents)" }.joined(separator: "\n\n")
            return """
            ## Project instructions
            Guidance from this project's AGENTS.md / CLAUDE.md / RIPPLE.md files. Treat it as \
            user-provided rules for this workspace and follow it.

            \(body)
            """
        }
    }

    /// Load every `AGENTS.md` / `CLAUDE.md` / `RIPPLE.md` from `workingDirectory` up to (and
    /// including) the git repo root. Files are returned repo-root-first; empty / whitespace-only files
    /// are skipped.
    static func load(workingDirectory: URL) -> Loaded {
        let chain = searchChain(from: workingDirectory)
        let root = chain.first ?? workingDirectory.standardizedFileURL
        var files: [File] = []
        for dir in chain {
            for name in fileNames {
                let url = dir.appendingPathComponent(name)
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                files.append(File(label: label(for: url, root: root), contents: trimmed))
            }
        }
        return Loaded(files: files)
    }

    /// The directory chain from the git repo root down to `workingDirectory` (inclusive), root-first.
    /// Walks up from the working directory, stopping inclusively at the first directory that holds a
    /// `.git` entry - a file (a worktree / submodule pointer) or a directory. When no ancestor is a
    /// repo root, only the working directory is returned.
    static func searchChain(from workingDirectory: URL) -> [URL] {
        var chain: [URL] = []
        var dir = workingDirectory.standardizedFileURL
        while true {
            chain.append(dir)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return chain.reversed() // repo root (inclusive), root-first
            }
            // `deletingLastPathComponent()` yields `/..` (not `/`) at the filesystem root for
            // some URL forms (e.g. those derived from `FileManager.temporaryDirectory`), so a
            // path-equality guard can spin forever. Standardize and require the parent to be
            // strictly shorter - the walk must make upward progress or stop.
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.pathComponents.count >= dir.pathComponents.count { break } // root, no `.git`
            dir = parent
        }
        return [workingDirectory.standardizedFileURL] // not in a repo -> working directory only
    }

    /// A file's path relative to `root` (so files in the root read as bare names like `AGENTS.md`, and
    /// nested ones as `src/CLAUDE.md`). Falls back to the bare filename when `url` isn't under `root`.
    private static func label(for url: URL, root: URL) -> String {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else {
            return url.lastPathComponent
        }
        return parts.dropFirst(rootParts.count).joined(separator: "/")
    }
}
