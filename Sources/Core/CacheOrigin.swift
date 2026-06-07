import Foundation

/// Discriminator for the cache subsystem that observed a cache event.
///
/// Stored as the raw string in `token_events.cache_origin`. V.19a-2
/// ships only `.prefixCache` (the MLXPrefixCache wrap from V.19a-1);
/// future cache subsystems extend this enum. The dashboard tile in
/// V.19a-4 groups cached-token rows by `cache_origin` to attribute
/// savings per subsystem.
public enum CacheOrigin: String, Sendable, CaseIterable, Equatable {
    /// MLXPrefixCache wrap (V.19a-1) — per-session KV prefix cache for
    /// MLX inference.
    case prefixCache = "prefix_cache"
    /// Reserved for future cache subsystems before they get their own
    /// case (e.g. a cross-session block store from V.19b). Dashboard
    /// tile groups these under "other" so unattributed rows remain
    /// visible.
    case other = "other"
}
