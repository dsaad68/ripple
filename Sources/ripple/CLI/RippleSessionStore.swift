import DeepAgents
import Foundation

/// One saved `ripple chat` session's metadata - the `meta.json` beside its message log under
/// `~/.ripple/sessions/<id>/`. Carries the `projectPath` so `ripple --resume` can list only the
/// sessions that ran in the current project, and the pinned `model` so a resume reselects it.
struct RippleSessionMeta: Codable, Identifiable, Sendable, Equatable {
    let id: String
    /// Absolute path of the working directory the session ran in (its agent root), so the resume
    /// picker can scope the list to the current project.
    var projectPath: String
    /// The planner the session last ran on (an on-device variant's text model id or a registered
    /// remote model's name), so resuming reselects it - see ``DeepAgentREPL/resolveVariant``.
    var model: String
    /// First user line, shown as the session's label in the resume picker.
    var title: String
    let createdAt: Date
    var updatedAt: Date
}

/// Persists `ripple chat` sessions to `~/.ripple/sessions/<id>/`, so a conversation can be resumed
/// with `ripple --resume <id>` (or picked from the list `ripple --resume` shows for the current
/// project). Each session directory holds a `meta.json` header and a `messages.jsonl` of the agent's
/// canonical `[AgentMessage]` history (model-agnostic - the OpenAI and LFM2 codecs adapt the same
/// on-disk form at run time, so a session created under one model resumes under another).
///
/// It doubles as the agent's ``AgentCheckpointer``: the same files that list and restore a session
/// also restore the agent's context on resume, so a reopened thread isn't amnesiac. Keyed by the
/// session id (a UUID, used verbatim as the agent `threadId`). The read/list/delete helpers are
/// `static` so the REPL's resume picker can scan sessions before an agent (and its store) exists.
actor RippleSessionStore: AgentCheckpointer {
    /// `~/.ripple/sessions` - the root every session directory lives under.
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ripple", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private let root: URL
    /// The working directory written into every meta this store saves (the session's project).
    private let projectPath: String
    /// The planner this store stamps into meta on save; updated by rebuilding the store on a
    /// `/model` switch so the pinned model tracks the most recent one used.
    private let model: String

    init(rootDirectory: URL = RippleSessionStore.defaultRoot, projectPath: URL, model: String) {
        root = rootDirectory
        self.projectPath = Self.canonicalPath(projectPath)
        self.model = model
    }

    // MARK: - AgentCheckpointer

    func load(_ threadId: String) -> [AgentMessage] {
        Self.messages(in: root, id: threadId)
    }

    func save(_ threadId: String, _ messages: [AgentMessage]) {
        let existing = Self.meta(in: root, id: threadId)
        let now = Date()
        let meta = RippleSessionMeta(
            id: threadId,
            projectPath: existing?.projectPath ?? projectPath,
            model: model.isEmpty ? (existing?.model ?? "") : model,
            title: Self.title(from: messages) ?? existing?.title ?? "New session",
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        Self.write(in: root, meta: meta, messages: messages)
    }

    // MARK: - Reading / listing (static: usable before a store exists)

    /// Every saved session that ran in `project`, most-recently-active first. Scans each session's
    /// `meta.json` (cheap - one small file per session) and filters by `projectPath`.
    nonisolated static func sessions(in root: URL = RippleSessionStore.defaultRoot, forProject project: URL) -> [RippleSessionMeta] {
        let wanted = canonicalPath(project)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        return dirs
            .compactMap { meta(in: root, id: $0.lastPathComponent) }
            .filter { $0.projectPath == wanted }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Decode one session's `meta.json`, or nil when missing / unreadable.
    nonisolated static func meta(in root: URL = RippleSessionStore.defaultRoot, id: String) -> RippleSessionMeta? {
        guard let data = try? Data(contentsOf: sessionDir(root, id).appendingPathComponent("meta.json")) else {
            return nil
        }
        return try? decoder().decode(RippleSessionMeta.self, from: data)
    }

    /// The agent history for a session, decoded from its `messages.jsonl` (used to seed the
    /// checkpointer and rebuild the display transcript on resume).
    nonisolated static func messages(in root: URL = RippleSessionStore.defaultRoot, id: String) -> [AgentMessage] {
        guard let data = try? Data(contentsOf: sessionDir(root, id).appendingPathComponent("messages.jsonl")) else {
            return []
        }
        let decoder = decoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(AgentMessage.self, from: Data($0)) }
    }

    /// Delete a session directory (and everything in it).
    nonisolated static func delete(in root: URL = RippleSessionStore.defaultRoot, id: String) {
        try? FileManager.default.removeItem(at: sessionDir(root, id))
    }

    // MARK: - Writing

    /// Write `messages.jsonl` then `meta.json` into the session directory (creating it). The directory
    /// is only made here, so a launched-but-never-saved session leaves nothing on disk. Messages are
    /// written first so `meta.json` acts as the commit marker: a crash mid-write can orphan messages
    /// (the session just won't list), but never leaves a listed/resumable meta pointing at missing or
    /// stale history.
    private nonisolated static func write(in root: URL, meta: RippleSessionMeta, messages: [AgentMessage]) {
        let dir = sessionDir(root, meta.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = encoder()
        var data = Data()
        for message in messages {
            guard let line = try? encoder.encode(message) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: dir.appendingPathComponent("messages.jsonl"), options: .atomic)
        if let header = try? encoder.encode(meta) {
            try? header.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    // MARK: - Helpers

    /// A canonical absolute path for project matching: symlinks resolved (so the same checkout opened
    /// via a symlink and via its real path match - e.g. `/tmp` vs `/private/tmp` on macOS) and
    /// `.`/`..` segments removed. Used for the stored `projectPath`, the resume query, and the
    /// `--resume <id>` project-scope check in ``DeepAgentREPL``.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// `<root>/<id>/`, sanitizing the id defensively so a stray key can't escape the root.
    private nonisolated static func sessionDir(_ root: URL, _ id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        return root.appendingPathComponent(safe, isDirectory: true)
    }

    /// ISO-8601 with fractional seconds, so two sessions created in the same wall-clock second still
    /// sort deterministically by `updatedAt` (e.g. a `/fresh` right after another) - plain `.iso8601`
    /// truncates to whole seconds, which would tie and leave the resume list's order to an unstable
    /// sort. Built fresh per call (`ISO8601DateFormatter` isn't `Sendable`); meta carries two dates,
    /// so the cost is trivial.
    private nonisolated static func iso8601Fractional() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601Fractional().string(from: date))
        }
        return encoder
    }

    private nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = iso8601Fractional().date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "not an ISO-8601 date: \(string)"
                )
            }
            return date
        }
        return decoder
    }

    /// First non-empty human line, trimmed, as the session's label. Compaction-synthesized summary
    /// turns are `.human` too, so they're skipped - otherwise the first save after a compaction would
    /// relabel the session with the summary boilerplate in the resume picker.
    private nonisolated static func title(from messages: [AgentMessage]) -> String? {
        guard let text = messages.first(where: { $0.role == .human && !$0.isSummary })?.text else { return nil }
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }
}

extension RippleSessionStore: CompactionArchive {
    /// Offload one compaction's evicted originals as the next `history/part-{n}.jsonl` beside the
    /// session's `messages.jsonl`, so the full pre-compaction transcript stays recoverable even
    /// though the live `messages.jsonl` now holds only `[summary] + tail`. Returns the part's path.
    func archive(_ messages: [AgentMessage], threadId: String) -> String? {
        Self.writeHistoryPart(in: root, id: threadId, messages: messages)
    }

    /// Write `messages` as a JSONL part under `<session>/history/`, numbered one past the highest
    /// existing part. Best-effort: returns nil if the directory or file can't be written.
    private nonisolated static func writeHistoryPart(
        in root: URL, id: String, messages: [AgentMessage]
    ) -> String? {
        let dir = sessionDir(root, id).appendingPathComponent("history", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        let fileURL = dir.appendingPathComponent("part-\(nextPartNumber(in: dir)).jsonl")
        let encoder = encoder()
        var data = Data()
        for message in messages {
            guard let line = try? encoder.encode(message) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return fileURL.path
    }

    /// One past the highest `part-{n}.jsonl` already in `dir` (1 for an empty/new history folder).
    private nonisolated static func nextPartNumber(in dir: URL) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return 1 }
        let numbers = files.compactMap { url -> Int? in
            let name = url.lastPathComponent
            guard name.hasPrefix("part-"), name.hasSuffix(".jsonl") else { return nil }
            return Int(name.dropFirst("part-".count).dropLast(".jsonl".count))
        }
        return (numbers.max() ?? 0) + 1
    }
}
