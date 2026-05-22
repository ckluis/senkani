import Foundation

/// V.18a-4 — receive-time privacy filter for OTLP attribute payloads.
///
/// Applied by `RuntimeTelemetryReceiver` between decode and persist.
/// Replaces the V.18a-3 placeholder of stashing `{"otlp_raw_b64": "…"}`
/// in `attributes_json` with a metadata-only, secret-redacted filtered
/// attribute map.
///
/// Three modes, selected per source via
/// `HandRuntimeTelemetry.CaptureMode`:
///
/// - `.metadata` (default): sensitive attribute keys (HTTP/RPC bodies,
///   headers, `process.env.*`) are dropped at receive. Non-sensitive
///   attribute values are still scanned by `SecretDetector` so an
///   accidentally-included API key in `db.statement` or `url.full`
///   never lands in storage.
///
/// - `.redactedBodies`: sensitive attribute keys are CAPTURED but
///   every value (sensitive and otherwise) is routed through
///   `SecretDetector` before persist.
///
/// - `.full`: every attribute persisted verbatim, no `SecretDetector`
///   pass. Operator opts into this via `HandManifest.runtime_telemetry
///   .capture = full` + a `validated_fields` map naming every captured
///   key — see `HandManifestLinter` warning.
///
/// Accepted-risk doc: `spec/architecture.md` "Runtime telemetry receiver
/// — privacy filter (Phase V.18a-4)" lists the SecretDetector coverage
/// gap (regex-based, won't catch novel secret formats; attribute keys
/// themselves are not scanned; protobuf bytes values are base64'd and
/// skipped).
public enum OTLPPrivacyFilter {

    /// OTLP attribute-key prefixes the `.metadata` mode drops entirely.
    /// Sourced from the OpenTelemetry semantic conventions for HTTP,
    /// RPC, messaging, database, and process attributes. Anchored to
    /// the full attribute key (case-sensitive, `key.hasPrefix(prefix)`).
    /// Conservative: when in doubt, drop. Add a prefix here when a
    /// real OTel producer emits something Senkani didn't anticipate.
    public static let sensitiveKeyPrefixes: [String] = [
        "http.request.body",
        "http.response.body",
        "http.request.header",
        "http.response.header",
        "http.request.cookies",
        "http.response.cookies",
        "rpc.request.body",
        "rpc.response.body",
        "rpc.request.metadata",
        "rpc.response.metadata",
        "messaging.message.body",
        "messaging.message.payload",
        "db.statement.parameters",
        "process.env.",
        "process.environment_variables",
        "user.email",
        "user.name",
        "enduser.id",
        "enduser.email",
        "client.address",
    ]

    /// Apply the privacy filter to one decoded attribute map.
    /// Returns the filtered map ready to be JSON-encoded into the
    /// span or log row's `attributes_json` column.
    ///
    /// The input attributes are the decoded OTLP key/value pairs
    /// (string-rendered — protobuf AnyValue.bytes_value is base64'd
    /// upstream by `OTLPDecoder`). Output preserves the same string
    /// shape so consumers don't have to type-juggle.
    public static func filter(
        attributes: [String: String],
        mode: HandRuntimeTelemetry.CaptureMode
    ) -> [String: String] {
        switch mode {
        case .full:
            return attributes
        case .metadata, .redactedBodies:
            var out: [String: String] = [:]
            out.reserveCapacity(attributes.count)
            for (key, value) in attributes {
                let isSensitive = isSensitiveKey(key)
                if isSensitive && mode == .metadata {
                    // Drop entirely.
                    continue
                }
                // .metadata mode keeps non-sensitive values; still
                // SecretDetector-scan in case a producer accidentally
                // stuffed an API key into a non-sensitive attribute.
                // .redactedBodies mode keeps sensitive values too but
                // always SecretDetector-scans every value.
                let scan = SecretDetector.scan(value)
                out[key] = scan.redacted
            }
            return out
        }
    }

    /// True if the OTLP attribute key matches any of the configured
    /// sensitive prefixes. Exposed for test assertions; the receiver
    /// uses `filter(attributes:mode:)` directly.
    public static func isSensitiveKey(_ key: String) -> Bool {
        for prefix in sensitiveKeyPrefixes {
            if key.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    /// Encode the filtered attribute map as a JSON object string.
    /// Stable key ordering (sorted) so tests can assert exact output.
    /// Returns `"{}"` on encode failure rather than throwing — the
    /// receiver MUST always produce a valid `attributes_json` value
    /// for the V.18a-1 NOT NULL column.
    public static func encodeJSON(_ attributes: [String: String]) -> String {
        guard !attributes.isEmpty else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(attributes),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}
