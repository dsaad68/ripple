import DeepAgents

/// Ripple's own release version, plus the line `ripple --version` prints - which pairs it with the
/// DeepAgents build it was compiled against. Ripple is published in lockstep with `deepagents-swift`,
/// so the two version numbers normally match.
enum RippleVersion {
    /// Semantic version string, e.g. "0.5.0".
    static let current = "0.5.0"

    /// Printed by `ripple --version`: ripple's version and the DeepAgents version it uses.
    static let versionLine = "ripple \(current) (DeepAgents-swift \(DeepAgentsVersion.current))"
}
