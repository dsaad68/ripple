import DeepAgents

/// Ripple's own release version, plus the line `ripple --version` prints - which pairs it with the
/// DeepAgents build it was compiled against. Ripple is published in lockstep with `deepagents-swift`
/// (see `scripts/publish-mirrors.sh`), so the two version numbers normally match.
enum RippleVersion {
    /// Semantic version string, e.g. "0.2.4".
    static let current = "0.2.4"

    /// Printed by `ripple --version`: ripple's version and the DeepAgents version it uses.
    static let versionLine = "ripple \(current) (DeepAgents-swift \(DeepAgentsVersion.current))"
}
