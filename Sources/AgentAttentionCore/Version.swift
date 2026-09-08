import Foundation

/// Display name is "Agent Warden"; the module, package and data directory keep the original
/// `AgentAttention` spelling because renaming them buys nothing and breaks paths.
public enum AgentAttentionVersion {
    public static let displayName = "Agent Warden"

    public static let string = "0.14.0"
    /// Bumped when the on-disk event/heartbeat/state formats change incompatibly.
    public static let storageGeneration = 1
}
