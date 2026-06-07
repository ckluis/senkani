import Foundation

/// V.13a-1 — persisted config for the OpenAI-compatible inference
/// endpoint (`senkani serve --openai`).
///
/// Stored as JSON under the top-level `openai_endpoint` key in
/// `~/.senkani/openai-endpoint.json`.
///
/// **Storage-format note.** The V.13 decomposition's acceptance text
/// (2026-05-27) named `~/.senkani/config.yaml`, but senkani ships zero
/// YAML: there is no Yams (or any YAML) dependency, the operator's
/// 2026-05-27 substrate decision pins `Package.resolved` ("no new
/// dependency"), and every other config on disk is JSON (`budget.json`,
/// `workspace.json`, `.senkani/config.json` via `AutoValidateConfig`).
/// This struct therefore reuses the `AutoValidateConfig` JSON load
/// pattern verbatim. The *substantive* contract is preserved: bind /
/// port / enabled (+ the `accept_network_bind` opt-in) persist under an
/// `openai_endpoint` namespace, and CLI flags override the loaded
/// values for the current invocation only (they do not write the file).
/// See the round's execution evidence + the filed follow-up for the
/// `.yaml` → `.json` divergence audit trail.
public struct OpenAIEndpointConfig: Codable, Sendable, Equatable {
    /// Bind address. Default `127.0.0.1` (loopback only).
    public var bind: String
    /// Bind port. Default 8470.
    public var port: Int
    /// Whether the endpoint is enabled. Persisted baseline; not yet
    /// consulted by v13a-1 (the verb starts on demand). Reserved for
    /// v13a-2+ provisioning / autostart wiring.
    public var enabled: Bool
    /// Operator opt-in to a non-loopback bind. Mirrors the
    /// `--accept-network-bind` CLI flag; either source satisfies the
    /// pre-flight guard (see `OpenAIListenerGuard`).
    public var acceptNetworkBind: Bool

    public static let defaultBind = "127.0.0.1"
    public static let defaultPort = 8470

    public static let `default` = OpenAIEndpointConfig(
        bind: defaultBind, port: defaultPort, enabled: false, acceptNetworkBind: false
    )

    public init(
        bind: String = defaultBind,
        port: Int = defaultPort,
        enabled: Bool = false,
        acceptNetworkBind: Bool = false
    ) {
        self.bind = bind.isEmpty ? OpenAIEndpointConfig.defaultBind : bind
        self.port = max(0, min(65535, port))
        self.enabled = enabled
        self.acceptNetworkBind = acceptNetworkBind
    }

    enum CodingKeys: String, CodingKey {
        case bind
        case port
        case enabled
        case acceptNetworkBind = "accept_network_bind"
    }

    // MARK: - Paths

    /// Default config file: `~/.senkani/openai-endpoint.json`.
    public static func defaultPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.senkani/openai-endpoint.json"
    }

    // MARK: - Loading

    /// Load the `openai_endpoint` block from `path`. Returns `.default`
    /// if the file is absent or the key is missing — mirrors
    /// `AutoValidateConfig.load`.
    public static func load(path: String = OpenAIEndpointConfig.defaultPath()) -> OpenAIEndpointConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = json["openai_endpoint"],
              let innerData = try? JSONSerialization.data(withJSONObject: inner),
              let config = try? JSONDecoder().decode(OpenAIEndpointConfig.self, from: innerData)
        else {
            return .default
        }
        return config
    }

    // MARK: - Saving

    /// Persist this config under the `openai_endpoint` key at `path`,
    /// preserving any sibling top-level keys already in the file.
    /// Atomic write so a concurrent reader never sees a half-written
    /// file.
    public func save(path: String = OpenAIEndpointConfig.defaultPath()) throws {
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        let selfData = try JSONEncoder().encode(self)
        let selfObj = try JSONSerialization.jsonObject(with: selfData)
        root["openai_endpoint"] = selfObj

        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    // MARK: - CLI override (invocation-only)

    /// Produce the effective config for a single invocation by
    /// overlaying any non-nil CLI flag values on top of the loaded
    /// config. Does NOT write the file — the override is invocation-only
    /// per the V.13a-1 contract.
    public func merging(bind: String?, port: Int?, acceptNetworkBind: Bool?) -> OpenAIEndpointConfig {
        OpenAIEndpointConfig(
            bind: bind ?? self.bind,
            port: port ?? self.port,
            enabled: self.enabled,
            acceptNetworkBind: acceptNetworkBind ?? self.acceptNetworkBind
        )
    }
}
