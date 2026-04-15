import Foundation

/// Budget-aware output truncation thresholds.
/// As a session approaches its budget limit, output caps tighten automatically.
/// When no budget is configured (remaining = 1.0), returns defaults with zero overhead.
public enum AdaptiveTruncation {

    /// Maximum output bytes based on budget remaining fraction (0.0...1.0).
    /// - >50%: 1MB (default)
    /// - 25-50%: 512KB
    /// - 10-25%: 256KB
    /// - <10%: 64KB (minimum — never truncate below this)
    public static func maxBytes(forBudgetRemaining remaining: Double) -> Int {
        if remaining > 0.50 { return 1_048_576 }  // 1MB
        if remaining > 0.25 { return 524_288 }     // 512KB
        if remaining > 0.10 { return 262_144 }     // 256KB
        return 65_536                               // 64KB
    }

    /// Sandbox line threshold based on budget remaining.
    /// - >50%: 20 lines (default)
    /// - 25-50%: 10 lines
    /// - <25%: 5 lines
    public static func sandboxThreshold(forBudgetRemaining remaining: Double) -> Int {
        if remaining > 0.50 { return 20 }
        if remaining > 0.25 { return 10 }
        return 5
    }
}
