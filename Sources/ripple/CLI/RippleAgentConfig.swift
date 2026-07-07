import CryptoKit
import DeepAgents
import Foundation

/// ripple's MCP servers + tool policy, loaded from JSON so the CLI has the same capabilities as the
/// Mispher app (ripple has no `UserDefaults`/Settings UI).
///
/// MCP servers use **Claude Code's `mcpServers` schema** and are merged from these sources, in
/// order (first definition of a given server name wins):
/// 1. `<project>/.mcp.json`        - the standard project-scoped Claude Code file.
/// 2. `<project>/.ripple/mcp.json` - ripple's own project config.
/// 3. `~/.ripple/mcp.json`         - a global fallback.
///
/// ```json
/// { "mcpServers": {
///     "api-server": { "type": "http", "url": "${API_BASE_URL:-https://api.example.com}/mcp",
///                     "headers": { "Authorization": "Bearer ${API_KEY}" } },
///     "local":      { "command": "/path/to/server", "args": [], "env": {} },
///     "oauth-srv":  { "type": "http", "url": "https://mcp.example.com/mcp", "oauth": {} }
/// } }
/// ```
/// `${VAR}` and `${VAR:-default}` are expanded from the process environment. An optional
/// `approvalMode` ("approve"/"ask"/"deny", default "ask") is a ripple extension; OAuth servers sign
/// in through the same browser loopback flow as the app, tokens persisting in the same Keychain.
///
/// The **tool policy** and the **per-project MCP trust** both live in `settings.json` (project
/// `<project>/.ripple/settings.json`, falling back to `~/.ripple/settings.json` for unset values) -
/// alongside the `models` the model loader reads. The `toolPolicy` key holds an ``AgentToolPolicy``
/// object; the `mcp` key maps each server name to its per-project trust (``MCPTrust``: whether the
/// project accepted the server, and an optional per-server approval override). Server *definitions*
/// stay in the `mcp.json` files above - `mcp` here only records the project's decision about them.
/// The `selectedModel` key records the project's last-used planner (set on a `/model` switch), so
/// reopening ripple here starts on it. A legacy `<scope>/.ripple/tool-policy.json` is folded into the
/// matching `settings.json` on first load and then removed.
enum RippleAgentConfig {
    static func loadServers(workingDirectory: URL) -> [MCPServerConfig] {
        loadServers(sources: sourceURLs(workingDirectory: workingDirectory))
    }

    /// Which config file `mcp add`/`remove` writes to, mirroring `claude mcp add --scope`.
    /// `project` (the default) is ripple's own project file - it carries the `approvalMode`
    /// extension; `shared` is the checked-in Claude Code `.mcp.json`; `user` is the global fallback.
    enum Scope: String, CaseIterable, Sendable {
        case project, shared, user

        /// The merge order used when loading (first definition of a name wins): the shared
        /// `.mcp.json`, then ripple's `.ripple/mcp.json`, then the global `~/.ripple/mcp.json`.
        static let mergeOrder: [Scope] = [.shared, .project, .user]

        func url(workingDirectory: URL) -> URL {
            switch self {
            case .project:
                return workingDirectory.appendingPathComponent(".ripple", isDirectory: true)
                    .appendingPathComponent("mcp.json")
            case .shared:
                return workingDirectory.appendingPathComponent(".mcp.json")
            case .user:
                return FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".ripple", isDirectory: true).appendingPathComponent("mcp.json")
            }
        }

        /// A short, human-readable label for the file (e.g. `.ripple/mcp.json`, `~/.ripple/mcp.json`).
        var label: String {
            switch self {
            case .project: return ".ripple/mcp.json"
            case .shared: return ".mcp.json"
            case .user: return "~/.ripple/mcp.json"
            }
        }
    }

    /// The three config sources paired with their scope, in load/merge order.
    static func scopedSources(workingDirectory: URL) -> [(scope: Scope, url: URL)] {
        Scope.mergeOrder.map { ($0, $0.url(workingDirectory: workingDirectory)) }
    }

    static func sourceURLs(workingDirectory: URL) -> [URL] {
        scopedSources(workingDirectory: workingDirectory).map(\.url)
    }

    /// Merge the Claude Code MCP configs found at `sources`, in order, with the first definition of
    /// a given server name winning. (Separated from the default source list so tests can supply
    /// their own without the real `~/.ripple/mcp.json` leaking in.)
    static func loadServers(sources: [URL]) -> [MCPServerConfig] {
        var seen: Set<String> = []
        var merged: [MCPServerConfig] = []
        for url in sources {
            guard let data = try? Data(contentsOf: url) else { continue }
            for config in parseClaudeMCP(data) where seen.insert(config.name).inserted {
                merged.append(config)
            }
        }
        return merged
    }

    /// The two `settings.json` sources, in read order: the project file, then the global fallback -
    /// the same files the model loader merges (see ``RippleModelConfig/sourceURLs(workingDirectory:)``).
    static func settingsSources(workingDirectory: URL) -> [URL] {
        RippleModelConfig.sourceURLs(workingDirectory: workingDirectory)
    }

    /// The project `settings.json` - the only file `/config` and the MCP trust prompt write to (the
    /// user file is a read-only fallback for defaults).
    static func projectSettingsURL(workingDirectory: URL) -> URL {
        settingsSources(workingDirectory: workingDirectory)[0]
    }

    // MARK: - Tool policy (settings.json `toolPolicy`)

    /// The project's tool policy: `settings.json` `toolPolicy`, project then `~/.ripple` fallback.
    /// Folds any legacy `tool-policy.json` into `settings.json` first, then returns a default policy
    /// when nothing is configured.
    static func loadPolicy(workingDirectory: URL) -> AgentToolPolicy {
        migrateLegacyPolicy(workingDirectory: workingDirectory)
        for url in settingsSources(workingDirectory: workingDirectory) {
            if let policy = decodePolicy(url) { return policy }
        }
        return AgentToolPolicy()
    }

    /// Persist `policy` into the project `settings.json` `toolPolicy` key (preserving `models` /
    /// `mcp` and other siblings), so the `/config` editor's changes survive the session.
    static func savePolicy(_ policy: AgentToolPolicy, workingDirectory: URL) throws {
        try writePolicy(policy, to: projectSettingsURL(workingDirectory: workingDirectory))
    }

    /// Decode the `toolPolicy` object from `settings.json` (JSON5-tolerant for hand edits), or nil
    /// when the file is missing / has no `toolPolicy`.
    static func decodePolicy(_ url: URL) -> AgentToolPolicy? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        struct File: Decodable { var toolPolicy: AgentToolPolicy? }
        return (try? decoder.decode(File.self, from: data))?.toolPolicy
    }

    /// Embed `policy` under the `toolPolicy` key of the file at `url`, preserving every other key
    /// (`models`, `mcp`) verbatim.
    private static func writePolicy(_ policy: AgentToolPolicy, to url: URL) throws {
        var root = readJSONObject(url) ?? [:]
        let data = try JSONEncoder().encode(policy)
        root["toolPolicy"] = try JSONSerialization.jsonObject(with: data)
        try writeJSONObject(root, to: url)
    }

    /// One-time migration: fold each scope's legacy `tool-policy.json` into the matching
    /// `settings.json` `toolPolicy` (only when that file has none yet, so a newer policy is never
    /// clobbered) and remove the legacy file. Best-effort - a failure leaves the legacy file in place.
    private static func migrateLegacyPolicy(workingDirectory: URL) {
        migratePolicyFile(
            legacy: rippleDir(workingDirectory).appendingPathComponent("tool-policy.json"),
            into: projectSettingsURL(workingDirectory: workingDirectory)
        )
        migratePolicyFile(
            legacy: rippleDir(FileManager.default.homeDirectoryForCurrentUser)
                .appendingPathComponent("tool-policy.json"),
            into: RippleModelConfig.userFileURL
        )
    }

    /// Fold one legacy `tool-policy.json` into the `toolPolicy` key of the file at `settings`, then
    /// remove the legacy file. A no-op when the legacy file is absent; when `settings` already carries
    /// a `toolPolicy` the fold is skipped (a newer policy is never clobbered) but the legacy file is
    /// still removed. Best-effort - any failure leaves the legacy file in place.
    static func migratePolicyFile(legacy: URL, into settings: URL) {
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        if let root = readJSONObject(settings), root["toolPolicy"] != nil {
            try? FileManager.default.removeItem(at: legacy)
            return
        }
        guard let data = try? Data(contentsOf: legacy),
              let policy = try? JSONDecoder().decode(AgentToolPolicy.self, from: data)
        else { return }
        // Only drop the legacy file once the new copy is safely written - a `try?` on both would lose
        // the policy entirely if the write failed (disk full, unwritable settings).
        guard (try? writePolicy(policy, to: settings)) != nil else { return }
        try? FileManager.default.removeItem(at: legacy)
    }

    // MARK: - Selected planner (settings.json `selectedModel`)

    /// The project's last-used planner model id, persisted on a `/model` switch so reopening ripple in
    /// this project starts on it. Read from `settings.json` `selectedModel`, project then `~/.ripple`
    /// fallback (so a user can set a global default planner). Nil when unset.
    static func loadSelectedModel(workingDirectory: URL) -> String? {
        for url in settingsSources(workingDirectory: workingDirectory) {
            if let model = decodeSelectedModel(url) { return model }
        }
        return nil
    }

    /// Record `model` as the project's selected planner in `settings.json` `selectedModel`, preserving
    /// the file's other keys (`models`, `mcp`, `toolPolicy`).
    static func saveSelectedModel(_ model: String, workingDirectory: URL) throws {
        let url = projectSettingsURL(workingDirectory: workingDirectory)
        var root = readJSONObject(url) ?? [:]
        root["selectedModel"] = model
        try writeJSONObject(root, to: url)
    }

    /// Decode the `selectedModel` string from one `settings.json` (JSON5-tolerant), or nil when absent.
    private static func decodeSelectedModel(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        struct File: Decodable { var selectedModel: String? }
        return (try? decoder.decode(File.self, from: data))?.selectedModel
    }

    // MARK: - Deep agent vision model + idle timeouts (settings.json)

    /// Default minutes a deep-agent model may sit idle before it's unloaded from memory.
    static let defaultIdleMinutes = 10

    /// The project's vision (VLM) model for the deep agent's `vision` subagent, persisted in
    /// `settings.json` `visionModel`. `nil` when unset (the caller falls back to the variant's default
    /// vision model); an empty string means the user turned vision off (text-only planner).
    static func loadVisionModel(workingDirectory: URL) -> String? {
        for url in settingsSources(workingDirectory: workingDirectory) {
            if let model = decodeString("visionModel", url) { return model }
        }
        return nil
    }

    /// Record `model` as the project's deep-agent vision model in `settings.json` `visionModel`
    /// (empty string = vision off), preserving the file's other keys.
    static func saveVisionModel(_ model: String, workingDirectory: URL) throws {
        let url = projectSettingsURL(workingDirectory: workingDirectory)
        var root = readJSONObject(url) ?? [:]
        root["visionModel"] = model
        try writeJSONObject(root, to: url)
    }

    /// Minutes the deep agent's planner may sit idle before it's unloaded (`0` keeps it resident).
    /// `settings.json` `plannerIdleMinutes`, project then `~/.ripple`; defaults to ``defaultIdleMinutes``.
    static func loadPlannerIdleMinutes(workingDirectory: URL) -> Int {
        loadIdleMinutes("plannerIdleMinutes", workingDirectory: workingDirectory)
    }

    /// Persist the planner idle timeout into the project `settings.json` `plannerIdleMinutes` key.
    static func savePlannerIdleMinutes(_ minutes: Int, workingDirectory: URL) throws {
        try saveInt("plannerIdleMinutes", minutes, workingDirectory: workingDirectory)
    }

    /// Minutes the deep agent's vision model may sit idle before it's unloaded (`0` keeps it resident).
    /// `settings.json` `visionIdleMinutes`, project then `~/.ripple`; defaults to ``defaultIdleMinutes``.
    static func loadVisionIdleMinutes(workingDirectory: URL) -> Int {
        loadIdleMinutes("visionIdleMinutes", workingDirectory: workingDirectory)
    }

    /// Persist the vision idle timeout into the project `settings.json` `visionIdleMinutes` key.
    static func saveVisionIdleMinutes(_ minutes: Int, workingDirectory: URL) throws {
        try saveInt("visionIdleMinutes", minutes, workingDirectory: workingDirectory)
    }

    private static func loadIdleMinutes(_ key: String, workingDirectory: URL) -> Int {
        for url in settingsSources(workingDirectory: workingDirectory) {
            if let value = decodeInt(key, url) { return value }
        }
        return defaultIdleMinutes
    }

    private static func saveInt(_ key: String, _ value: Int, workingDirectory: URL) throws {
        let url = projectSettingsURL(workingDirectory: workingDirectory)
        var root = readJSONObject(url) ?? [:]
        root[key] = value
        try writeJSONObject(root, to: url)
    }

    /// Decode a string value for `key` from one `settings.json` (JSON5-tolerant), or nil when absent.
    private static func decodeString(_ key: String, _ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return root[key] as? String
    }

    /// Decode an integer value for `key` from one `settings.json`, or nil when absent.
    private static func decodeInt(_ key: String, _ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return (root[key] as? NSNumber)?.intValue
    }

    // MARK: - Developer message log (settings.json `logMessages`)

    /// Whether `ripple chat` writes the developer message log (a JSONL transcript of each run, with
    /// timing/round/tool telemetry) into the session folder. **Off by default** - it's a debug aid,
    /// distinct from the resumable `messages.jsonl` checkpoint. Toggled in `/config`; the `--log <dir>`
    /// flag forces it on regardless. Read from `settings.json` `logMessages`, project then `~/.ripple`.
    static func loadLogMessages(workingDirectory: URL) -> Bool {
        for url in settingsSources(workingDirectory: workingDirectory) {
            if let value = decodeLogMessages(url) { return value }
        }
        return false
    }

    /// Persist the developer-log toggle into the project `settings.json` `logMessages` key, preserving
    /// the file's other keys (`models`, `mcp`, `toolPolicy`, `selectedModel`).
    static func saveLogMessages(_ enabled: Bool, workingDirectory: URL) throws {
        let url = projectSettingsURL(workingDirectory: workingDirectory)
        var root = readJSONObject(url) ?? [:]
        root["logMessages"] = enabled
        try writeJSONObject(root, to: url)
    }

    /// Decode the `logMessages` bool from one `settings.json` (JSON5-tolerant), or nil when absent.
    private static func decodeLogMessages(_ url: URL) -> Bool? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        struct File: Decodable { var logMessages: Bool? }
        return (try? decoder.decode(File.self, from: data))?.logMessages
    }

    // MARK: - Prefix KV disk cache (settings.json `prefixKVCache`)

    /// Whether the on-device planner persists its reusable prompt-prefix KV (system + tools) under
    /// `~/.cache/deepagents/prefix-kv`, so a fresh launch resumes it and skips the multi-second
    /// prompt prefill. **On by default** - snapshots can be a few hundred MB per model, so it's
    /// user-toggleable in `/config`. Read from `settings.json`, project then `~/.ripple`.
    static func loadPrefixKVCache(workingDirectory: URL) -> Bool {
        for url in settingsSources(workingDirectory: workingDirectory) {
            if let value = decodePrefixKVCache(url) { return value }
        }
        return true
    }

    /// Persist the prefix-cache toggle into the project `settings.json` `prefixKVCache` key,
    /// preserving the file's other keys.
    static func savePrefixKVCache(_ enabled: Bool, workingDirectory: URL) throws {
        let url = projectSettingsURL(workingDirectory: workingDirectory)
        var root = readJSONObject(url) ?? [:]
        root["prefixKVCache"] = enabled
        try writeJSONObject(root, to: url)
    }

    /// Decode the `prefixKVCache` bool from one `settings.json` (JSON5-tolerant), or nil when absent.
    private static func decodePrefixKVCache(_ url: URL) -> Bool? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        struct File: Decodable { var prefixKVCache: Bool? }
        return (try? decoder.decode(File.self, from: data))?.prefixKVCache
    }

    // MARK: - Per-project MCP trust (settings.json `mcp`)

    /// A project's decision about one MCP server: whether it accepted the server here, and an
    /// optional per-server approval override (when set, it overrides the server's `mcp.json`
    /// `approvalMode` for this project). Per-tool approvals are intentionally not modeled yet - the
    /// `mcp.<server>` object is left extensible so a `tools` map can be added later.
    struct MCPTrust: Sendable, Equatable {
        var accepted: Bool
        var approval: ToolApprovalMode?
        /// A fingerprint of the server *definition* (transport/command/args/url) at the time the
        /// decision was made. When the definition later changes under the same name the stored
        /// fingerprint no longer matches and the server is re-prompted (see ``trustDecided(for:in:)``),
        /// so a redefined server can't silently inherit an old accept/approval. Nil for entries
        /// written before fingerprinting existed (treated as a mismatch, i.e. re-prompt once).
        var fingerprint: String?
    }

    /// The recorded trust for `server` if it still applies: a decision exists for the server's name
    /// AND was made for the same definition (matching ``fingerprint(for:)``). Returns nil for a new
    /// server, or one whose definition changed under the same name - the caller then re-prompts.
    static func trustDecided(for server: MCPServerConfig, in trust: [String: MCPTrust]) -> MCPTrust? {
        guard let known = trust[server.name], known.fingerprint == fingerprint(for: server) else { return nil }
        return known
    }

    /// A stable fingerprint of the execution-defining fields of an MCP server (transport, command,
    /// args, url, auth) - what code runs and where it connects. Excludes `env`/`headers`, which carry
    /// secrets/tokens that legitimately rotate without changing the trust decision.
    static func fingerprint(for server: MCPServerConfig) -> String {
        let parts = [
            "kind=\(server.kind.rawValue)",
            "auth=\(server.auth.rawValue)",
            "command=\(server.command)",
            "url=\(server.url)",
            "args=" + server.args.joined(separator: "\u{1F}")
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1E}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The project's MCP trust map: `settings.json` `mcp`, project entries winning over the
    /// `~/.ripple` fallback. A server absent from the result has not been decided here yet (the
    /// first-load accept/reject prompt applies).
    static func loadMCPTrust(workingDirectory: URL) -> [String: MCPTrust] {
        var merged: [String: MCPTrust] = [:]
        // User first, then project, so a project decision overrides the global default per server.
        for url in settingsSources(workingDirectory: workingDirectory).reversed() {
            for (name, trust) in decodeMCPTrust(url) { merged[name] = trust }
        }
        return merged
    }

    /// Record the project's decision about server `name` in the project `settings.json` `mcp` key,
    /// preserving every other server and the file's other keys.
    static func saveMCPTrust(
        name: String, accepted: Bool, approval: ToolApprovalMode? = nil,
        fingerprint: String? = nil, workingDirectory: URL
    ) throws {
        let url = projectSettingsURL(workingDirectory: workingDirectory)
        var root = readJSONObject(url) ?? [:]
        var mcp = root["mcp"] as? [String: Any] ?? [:]
        var entry = mcp[name] as? [String: Any] ?? [:]
        entry["accepted"] = accepted
        if let approval { entry["approval"] = approval.rawValue }
        if let fingerprint { entry["fingerprint"] = fingerprint }
        mcp[name] = entry
        root["mcp"] = mcp
        try writeJSONObject(root, to: url)
    }

    /// Decode the `mcp` trust map from one `settings.json` (JSON5-tolerant), or `[:]` when absent.
    private static func decodeMCPTrust(_ url: URL) -> [String: MCPTrust] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        struct File: Decodable {
            struct Entry: Decodable {
                var accepted: Bool?
                var approval: ToolApprovalMode?
                var fingerprint: String?
            }

            var mcp: [String: Entry]?
        }
        guard let file = try? decoder.decode(File.self, from: data), let mcp = file.mcp else { return [:] }
        return mcp.mapValues {
            MCPTrust(accepted: $0.accepted ?? false, approval: $0.approval, fingerprint: $0.fingerprint)
        }
    }

    /// `<base>/.ripple/` - the config directory under a project root or the home folder.
    private static func rippleDir(_ base: URL) -> URL {
        base.appendingPathComponent(".ripple", isDirectory: true)
    }

    // MARK: - Writing servers (`mcp add` / `mcp remove`)

    /// The effective (merged, first-source-wins) servers, each tagged with the scope it loaded from,
    /// for `mcp list` - which shows every server's origin.
    static func resolvedServers(workingDirectory: URL) -> [(scope: Scope, config: MCPServerConfig)] {
        var seen: Set<String> = []
        var result: [(Scope, MCPServerConfig)] = []
        for (scope, url) in scopedSources(workingDirectory: workingDirectory) {
            guard let data = try? Data(contentsOf: url) else { continue }
            for config in parseClaudeMCP(data) where seen.insert(config.name).inserted {
                result.append((scope, config))
            }
        }
        return result
    }

    /// The scopes whose file currently defines a server named `name` (for `mcp remove`'s "it's
    /// actually defined in <scope>" hint when the chosen scope doesn't have it).
    static func scopesDefining(name: String, workingDirectory: URL) -> [Scope] {
        scopedSources(workingDirectory: workingDirectory).compactMap { scope, url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return parseClaudeMCP(data).contains { $0.name == name } ? scope : nil
        }
    }

    /// Insert (or replace) the raw Claude-schema `entry` for server `name` in the `mcpServers`
    /// object of the file at `url`, then atomic-write it pretty-printed. Every other server is
    /// preserved verbatim - we mutate the file's parsed JSON object directly rather than re-encoding
    /// `[MCPServerConfig]`, so untouched siblings keep their `${VAR}` placeholders and any extra
    /// keys (going through the config model would expand those to literals). Creates `.ripple/` if
    /// needed (mirrors ``savePolicy``).
    static func saveServerEntry(name: String, _ entry: [String: Any], to url: URL) throws {
        var root = readJSONObject(url) ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[name] = entry
        root["mcpServers"] = servers
        try writeJSONObject(root, to: url)
    }

    /// Remove server `name` from the `mcpServers` object of the file at `url`, preserving every
    /// other server verbatim. Returns `false` (writing nothing) when the file has no such server.
    @discardableResult
    static func removeServerEntry(name: String, from url: URL) throws -> Bool {
        guard var root = readJSONObject(url),
              var servers = root["mcpServers"] as? [String: Any], servers[name] != nil
        else { return false }
        servers[name] = nil
        root["mcpServers"] = servers
        try writeJSONObject(root, to: url)
        return true
    }

    /// Read a JSON object file into a mutable dictionary (nil when missing or not an object). Shared
    /// with ``RippleModelConfig`` so both can edit one key of a config file while preserving the rest.
    /// Strict JSON is read directly; a JSON5 hand edit (comments / trailing commas) is tolerated via a
    /// second pass so a partial-key write never misreads a commented file as empty and drops siblings
    /// like `models` (the comments themselves are not preserved across the rewrite).
    static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        guard let node = try? decoder.decode(JSONNode.self, from: data), case .object(let dict) = node
        else { return nil }
        return dict.mapValues(\.any)
    }

    /// Atomic-write `object` pretty-printed (creating the parent dir). Shared with ``RippleModelConfig``.
    static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    /// Parse a Claude Code `{ "mcpServers": { ... } }` document into our configs (sorted by name
    /// for a stable order), expanding `${VAR}` references. Returns `[]` on malformed input.
    static func parseClaudeMCP(_ data: Data) -> [MCPServerConfig] {
        guard let file = try? JSONDecoder().decode(ClaudeMCPFile.self, from: data) else { return [] }
        return file.mcpServers
            .map { name, spec in spec.config(name: name) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Claude Code schema

    private struct ClaudeMCPFile: Decodable {
        let mcpServers: [String: ClaudeMCPServer]
    }

    private struct ClaudeMCPServer: Decodable {
        var type: String?
        var url: String?
        var headers: [String: String]?
        var command: String?
        var args: [String]?
        var env: [String: String]?
        var oauth: OAuthSpec?
        var approvalMode: String? // ripple extension; not part of Claude Code's schema

        struct OAuthSpec: Decodable { var authServerMetadataUrl: String? }

        func config(name: String) -> MCPServerConfig {
            let isHTTP = type == "http" || type == "sse" || (type == nil && url != nil)
            let approval = approvalMode.flatMap(ToolApprovalMode.init(rawValue:)) ?? .ask
            return MCPServerConfig(
                id: RippleAgentConfig.stableID(for: name),
                name: name,
                kind: isHTTP ? .http : .stdio,
                isEnabled: true,
                command: expand(command ?? ""),
                args: (args ?? []).map(expand),
                env: (env ?? [:]).mapValues(expand),
                url: expand(url ?? ""),
                headers: (headers ?? [:]).mapValues(expand),
                auth: oauth != nil ? .oauth : .none,
                approvalMode: approval
            )
        }
    }

    /// A stable id derived from the server name, so an OAuth server keeps the same Keychain account
    /// (and the same client cache key) across launches even though the file carries no id.
    private static func stableID(for name: String) -> UUID {
        let bytes = Array(Insecure.MD5.hash(data: Data("mispher.mcp:\(name)".utf8)))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Expand `${VAR}` and `${VAR:-default}` references in a config value against the process
/// environment (`${VAR:-default}` falls back to `default` when `VAR` is unset or empty). Text
/// without `${` is returned unchanged. An unterminated `${` is left as-is.
func expand(_ value: String) -> String {
    guard value.contains("${") else { return value }
    var result = ""
    var rest = Substring(value)
    while let open = rest.range(of: "${") {
        result += rest[..<open.lowerBound]
        guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
            result += rest[open.lowerBound...]
            return result
        }
        let expression = rest[open.upperBound ..< close]
        let name: Substring
        let fallback: String?
        if let sep = expression.range(of: ":-") {
            name = expression[..<sep.lowerBound]
            fallback = String(expression[sep.upperBound...])
        } else {
            name = expression
            fallback = nil
        }
        let environment = ProcessInfo.processInfo.environment[String(name)]
        let resolved = (environment?.isEmpty == false) ? environment! : (fallback ?? "")
        result += resolved
        rest = rest[rest.index(after: close)...]
    }
    result += rest
    return result
}

/// A decoded JSON value, used only to read a JSON5 (commented / trailing-comma) config file into the
/// `[String: Any]` shape ``RippleAgentConfig/readJSONObject(_:)`` mutates - `JSONSerialization` can't
/// parse JSON5, but `JSONDecoder(allowsJSON5:)` can. Bridged back to `Any` for the existing writers.
private enum JSONNode: Decodable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONNode])
    case object([String: JSONNode])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: `Bool` before the number types (a JSON bool must not become 0/1), the
        // integer form before the floating one (so `4096` stays an Int), then the container types.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONNode].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONNode].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value"
            )
        }
    }

    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.any)
        case .object(let dict): dict.mapValues(\.any)
        }
    }
}
