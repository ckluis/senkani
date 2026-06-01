import Foundation

/// V.13b-4a — the SINGLE mandatory serve-path constructor for
/// `ClaudeAPIChatEngine`. It is the structural enforcement of the v13b-4
/// acceptance "Direct HTTPS bypass: NONE": the serve path builds the engine
/// ONLY through `make(...)`, which ALWAYS routes the engine's `URLSession`
/// through the loopback egress daemon (HTTPS `connectionProxyDictionary`)
/// and NEVER hands back a direct / `URLSession.shared` engine.
///
/// Why a dedicated factory (Schneier P0): `ClaudeAPIChatEngine.init` defaults
/// `session: .shared`, which has no proxy and would egress DIRECTLY to
/// api.anthropic.com — bypassing the daemon, its allowlist, and the
/// `egress_decisions` audit row. A copy-pasted `ClaudeAPIChatEngine(apiKey:)`
/// on the serve path would silently open exactly that hole. Routing every
/// serve construction through this factory makes "no direct bypass" a
/// structural property, not a runtime hope.
///
/// TLS trust (Schneier P1): the egress daemon CONNECT-tunnels HTTPS — it does
/// NOT terminate TLS — so the engine's TLS session is END-TO-END to
/// api.anthropic.com and MUST keep full certificate verification. This
/// factory sets ONLY `connectionProxyDictionary` and builds the session with
/// NO `URLSessionDelegate`, so default (strict) TLS evaluation is preserved.
/// The Chromium `NODE_TLS_REJECT_UNAUTHORIZED=0` posture does NOT apply here.
///
/// Daemon-down (panel P2): when the egress daemon's port file is absent /
/// unreadable, `make` THROWS `egressDaemonUnavailable` — a STRUCTURAL
/// REFUSAL. It never falls back to a direct session (that would defeat the
/// whole guarantee).
public enum ClaudeAPIServeEngineFactoryError: Error, Equatable, CustomStringConvertible {
    /// The egress daemon's loopback port could not be resolved (file absent,
    /// unreadable, or a non-positive integer). Carries an operator-actionable
    /// hint; no upstream/secret content.
    case egressDaemonUnavailable(reason: String)

    public var description: String {
        switch self {
        case .egressDaemonUnavailable(let reason):
            return "egress daemon unavailable: \(reason)"
        }
    }
}

public enum ClaudeAPIServeEngineFactory {

    /// Canonical path the egress daemon writes its bound loopback port to
    /// (see `EgressListener.Config.portFilePath` / `EgressCommand`).
    public static let egressPortPath = NSHomeDirectory() + "/.senkani/egress.port"

    /// Read the egress daemon's loopback port. Returns nil when the file is
    /// absent / unreadable / not a valid TCP port. Trim whitespace+newlines,
    /// `Int(...)`, then require `1...65535` — the legitimate daemon writer
    /// only ever emits a `UInt16`-bounded value (`EgressListener.writePortFile`),
    /// so the upper bound (parity with `EgressCommand.readPort`) rejects a
    /// corrupt/out-of-range stale file rather than driving a bogus proxy port.
    public static func readEgressPort(path: String = egressPortPath) -> Int? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0, port < 65536
        else { return nil }
        return port
    }

    /// Build a `URLSessionConfiguration` whose HTTPS traffic is routed
    /// through the loopback egress daemon at `port`. TLS verification is left
    /// DEFAULT-ON (no delegate, no protocol downgrade) because the daemon
    /// CONNECT-tunnels without terminating TLS.
    public static func proxiedConfiguration(port: Int) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
        return config
    }

    /// Construct the serve-path Claude engine routed through the egress
    /// daemon. THROWS `egressDaemonUnavailable` (a structural refusal) when
    /// the daemon port is unresolvable — NEVER returns a direct / `.shared`
    /// engine. Injects `RetryPolicy.serveSafe` (bounds backoff SLEEP) plus a
    /// real per-request `requestTimeout` (bounds each upstream round-trip) so
    /// a rate-limited or hung upstream can't park the listener thread.
    public static func make(
        apiKey: String,
        requestTimeout: TimeInterval = 30,
        retryPolicy: ClaudeAPIChatEngine.RetryPolicy = .serveSafe,
        portPath: String = egressPortPath,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    ) throws -> ClaudeAPIChatEngine {
        guard let port = readEgressPort(path: portPath) else {
            throw ClaudeAPIServeEngineFactoryError.egressDaemonUnavailable(
                reason: "no egress daemon port at \(portPath); start it with `senkani egress` before serving the Anthropic arm"
            )
        }
        let session = URLSession(configuration: proxiedConfiguration(port: port))
        return ClaudeAPIChatEngine(
            apiKey: apiKey,
            session: session,
            endpoint: endpoint,
            retryPolicy: retryPolicy,
            requestTimeout: requestTimeout
        )
    }
}
