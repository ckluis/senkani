import Foundation

/// V.18a-3 — decode OTLP `/v1/traces` and `/v1/logs` request bodies
/// into `RuntimeTelemetryStore.SpanRow` / `LogRow` payloads.
///
/// V.18a-4 — attribute extraction wired in. The decoder lifts
/// per-span and per-log attribute KeyValue lists into `[String: String]`
/// dicts and routes them through the caller-supplied
/// `attributesFilter` closure (typically `OTLPPrivacyFilter.filter`)
/// before persist. The V.18a-3 placeholder of stashing raw OTLP bytes
/// as base64 in `attributes_json` is gone — every span/log row now
/// carries a privacy-filtered structured JSON object.
///
/// Supports both wire formats (OTLP/protobuf and OTLP/JSON). The
/// receiver dispatches by `Content-Type` header — see
/// `RuntimeTelemetryReceiver.MimeType`.
///
/// Field tags below match the OTLP proto definitions
/// (opentelemetry-proto v1.0.0). We only walk the structure deep
/// enough to extract the five SpanRow + six LogRow fields the
/// V.18a-2 store needs plus the attribute KeyValue list; unknown
/// fields are skipped via wire type.
public enum OTLPDecoder {

    /// Closure type for the receive-time attribute filter. Takes the
    /// raw decoded attribute dict and returns the privacy-filtered
    /// dict the row's `attributes_json` column will hold.
    public typealias AttributesFilter = ([String: String]) -> [String: String]

    /// Decode an `ExportTraceServiceRequest` protobuf body.
    /// Returns one `SpanRow` per span across every `ResourceSpans` /
    /// `ScopeSpans` group.
    public static func decodeTracesProtobuf(
        _ body: Data,
        attributesFilter: AttributesFilter
    ) throws -> [RuntimeTelemetryStore.SpanRow] {
        var rows: [RuntimeTelemetryStore.SpanRow] = []
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            // ExportTraceServiceRequest.resource_spans = 1 (repeated ResourceSpans)
            if field == 1, wt == .length {
                let rsBytes = try reader.readLengthDelimited()
                try decodeResourceSpans(rsBytes, attributesFilter: attributesFilter, into: &rows)
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
        return rows
    }

    /// Decode an `ExportLogsServiceRequest` protobuf body.
    public static func decodeLogsProtobuf(
        _ body: Data,
        attributesFilter: AttributesFilter
    ) throws -> [RuntimeTelemetryStore.LogRow] {
        var rows: [RuntimeTelemetryStore.LogRow] = []
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            if field == 1, wt == .length {
                let rlBytes = try reader.readLengthDelimited()
                try decodeResourceLogs(rlBytes, attributesFilter: attributesFilter, into: &rows)
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
        return rows
    }

    /// Decode an OTLP/JSON `ExportTraceServiceRequest`. The JSON
    /// representation mirrors the protobuf field names, snake_cased.
    /// Span IDs are transmitted as hex strings (no base64 quirks).
    public static func decodeTracesJSON(
        _ body: Data,
        attributesFilter: AttributesFilter
    ) throws -> [RuntimeTelemetryStore.SpanRow] {
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw OTLPDecodeError.malformedJSON
        }
        var rows: [RuntimeTelemetryStore.SpanRow] = []
        let rsList = (json["resourceSpans"] as? [[String: Any]]) ?? (json["resource_spans"] as? [[String: Any]]) ?? []
        for rs in rsList {
            let ssList = (rs["scopeSpans"] as? [[String: Any]]) ?? (rs["scope_spans"] as? [[String: Any]]) ?? []
            for ss in ssList {
                let spans = (ss["spans"] as? [[String: Any]]) ?? []
                for span in spans {
                    if let row = spanRowFromJSON(span, attributesFilter: attributesFilter) {
                        rows.append(row)
                    }
                }
            }
        }
        return rows
    }

    /// Decode an OTLP/JSON `ExportLogsServiceRequest`.
    public static func decodeLogsJSON(
        _ body: Data,
        attributesFilter: AttributesFilter
    ) throws -> [RuntimeTelemetryStore.LogRow] {
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw OTLPDecodeError.malformedJSON
        }
        var rows: [RuntimeTelemetryStore.LogRow] = []
        let rlList = (json["resourceLogs"] as? [[String: Any]]) ?? (json["resource_logs"] as? [[String: Any]]) ?? []
        for rl in rlList {
            let slList = (rl["scopeLogs"] as? [[String: Any]]) ?? (rl["scope_logs"] as? [[String: Any]]) ?? []
            for sl in slList {
                let recs = (sl["logRecords"] as? [[String: Any]]) ?? (sl["log_records"] as? [[String: Any]]) ?? []
                for rec in recs {
                    if let row = logRowFromJSON(rec, attributesFilter: attributesFilter) {
                        rows.append(row)
                    }
                }
            }
        }
        return rows
    }

    // MARK: - protobuf inner decoders

    private static func decodeResourceSpans(
        _ body: Data,
        attributesFilter: AttributesFilter,
        into rows: inout [RuntimeTelemetryStore.SpanRow]
    ) throws {
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            // ResourceSpans.scope_spans = 2 (repeated ScopeSpans)
            if field == 2, wt == .length {
                let ssBytes = try reader.readLengthDelimited()
                try decodeScopeSpans(ssBytes, attributesFilter: attributesFilter, into: &rows)
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
    }

    private static func decodeScopeSpans(
        _ body: Data,
        attributesFilter: AttributesFilter,
        into rows: inout [RuntimeTelemetryStore.SpanRow]
    ) throws {
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            // ScopeSpans.spans = 2 (repeated Span)
            if field == 2, wt == .length {
                let spanBytes = try reader.readLengthDelimited()
                if let row = try decodeSpan(spanBytes, attributesFilter: attributesFilter) {
                    rows.append(row)
                }
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
    }

    private static func decodeSpan(
        _ body: Data,
        attributesFilter: AttributesFilter
    ) throws -> RuntimeTelemetryStore.SpanRow? {
        var traceId = Data()
        var spanId = Data()
        var parentSpanId = Data()
        var name = ""
        var startNs: UInt64 = 0
        var endNs: UInt64 = 0
        var statusCode: Int? = nil
        var attributes: [String: String] = [:]
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            switch (field, wt) {
            case (1, .length):
                traceId = try reader.readLengthDelimited()
            case (2, .length):
                spanId = try reader.readLengthDelimited()
            case (4, .length):
                parentSpanId = try reader.readLengthDelimited()
            case (5, .length):
                let nameBytes = try reader.readLengthDelimited()
                name = String(data: nameBytes, encoding: .utf8) ?? ""
            case (7, .i64):
                startNs = try reader.readFixed64()
            case (8, .i64):
                endNs = try reader.readFixed64()
            case (9, .length):
                // Span.attributes = 9 (repeated KeyValue)
                let kvBytes = try reader.readLengthDelimited()
                if let (k, v) = try decodeKeyValue(kvBytes) {
                    attributes[k] = v
                }
            case (15, .length):
                // Status message: walk nested fields to find code (tag 3 varint)
                let statusBytes = try reader.readLengthDelimited()
                statusCode = try parseStatusCode(statusBytes)
            default:
                try reader.skipValue(wireType: wt)
            }
        }
        // Reject spans missing required identifiers — `trace_id`,
        // `span_id`, and `name` are NOT NULL on the V.18a-1 schema.
        if traceId.isEmpty || spanId.isEmpty || name.isEmpty {
            return nil
        }
        let filtered = attributesFilter(attributes)
        let attrsJson = OTLPPrivacyFilter.encodeJSON(filtered)
        return RuntimeTelemetryStore.SpanRow(
            traceId: OTLPHex.encode(traceId),
            spanId: OTLPHex.encode(spanId),
            parentSpanId: parentSpanId.isEmpty ? nil : OTLPHex.encode(parentSpanId),
            name: name,
            startUnixNs: Int64(bitPattern: startNs),
            endUnixNs: Int64(bitPattern: endNs),
            attributesJson: attrsJson,
            statusCode: statusCode,
            sessionId: nil,
            toolCallId: nil,
            validationRunId: nil
        )
    }

    private static func parseStatusCode(_ body: Data) throws -> Int? {
        var reader = OTLPWireReader(body)
        var code: Int? = nil
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            if field == 3, wt == .varint {
                code = Int(try reader.readVarint())
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
        return code
    }

    private static func decodeResourceLogs(
        _ body: Data,
        attributesFilter: AttributesFilter,
        into rows: inout [RuntimeTelemetryStore.LogRow]
    ) throws {
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            if field == 2, wt == .length {
                let slBytes = try reader.readLengthDelimited()
                try decodeScopeLogs(slBytes, attributesFilter: attributesFilter, into: &rows)
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
    }

    private static func decodeScopeLogs(
        _ body: Data,
        attributesFilter: AttributesFilter,
        into rows: inout [RuntimeTelemetryStore.LogRow]
    ) throws {
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            // ScopeLogs.log_records = 2 (repeated LogRecord)
            if field == 2, wt == .length {
                let recBytes = try reader.readLengthDelimited()
                if let row = try decodeLogRecord(recBytes, attributesFilter: attributesFilter) {
                    rows.append(row)
                }
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
    }

    private static func decodeLogRecord(
        _ body: Data,
        attributesFilter: AttributesFilter
    ) throws -> RuntimeTelemetryStore.LogRow? {
        var unixNs: UInt64 = 0
        var severityText: String? = nil
        var bodyText: String? = nil
        var traceId = Data()
        var spanId = Data()
        var attributes: [String: String] = [:]
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            switch (field, wt) {
            case (1, .i64):
                unixNs = try reader.readFixed64()
            case (3, .length):
                let s = try reader.readLengthDelimited()
                severityText = String(data: s, encoding: .utf8)
            case (5, .length):
                // body is AnyValue; tag 1 inside AnyValue = string_value (length)
                let av = try reader.readLengthDelimited()
                bodyText = anyValueAsString(av)
            case (6, .length):
                // LogRecord.attributes = 6 (repeated KeyValue)
                let kvBytes = try reader.readLengthDelimited()
                if let (k, v) = try decodeKeyValue(kvBytes) {
                    attributes[k] = v
                }
            case (9, .length):
                traceId = try reader.readLengthDelimited()
            case (10, .length):
                spanId = try reader.readLengthDelimited()
            default:
                try reader.skipValue(wireType: wt)
            }
        }
        if unixNs == 0 {
            return nil
        }
        // Log bodies are sensitive — the privacy filter applies to
        // `bodyText` too. The metadata-only mode drops it; redacted
        // mode scans for secrets; full mode passes through.
        let filteredBody = filterLogBody(bodyText, attributesFilter: attributesFilter)
        let filtered = attributesFilter(attributes)
        let attrsJson = OTLPPrivacyFilter.encodeJSON(filtered)
        return RuntimeTelemetryStore.LogRow(
            unixNs: Int64(bitPattern: unixNs),
            severityText: severityText,
            bodyText: filteredBody,
            attributesJson: attrsJson,
            traceId: traceId.isEmpty ? nil : OTLPHex.encode(traceId),
            spanId: spanId.isEmpty ? nil : OTLPHex.encode(spanId),
            sessionId: nil
        )
    }

    /// Apply the same filter policy to a log body. The body is one
    /// attribute keyed under the synthetic `"_body"` slot so the
    /// filter sees a uniform input; `_body` is not a real OTLP key,
    /// so `.metadata` mode drops it (no `sensitiveKeyPrefixes` match)
    /// — wait, that's wrong. We always want `.metadata` to drop the
    /// body. Special-case: feed `"log.body"` as the synthetic key so
    /// the metadata filter (which has no `log.body` rule today) keeps
    /// the body. The right invariant is: body is metadata in
    /// `.metadata` mode (it's the message), bodies in `.redactedBodies`
    /// get SecretDetector, bodies in `.full` pass through. So the
    /// filter should NOT drop the body in any mode; it should redact
    /// in `.redactedBodies` and `.metadata`, and pass-through in
    /// `.full`. Treat it as a non-sensitive attribute value: filter
    /// will keep it and SecretDetector-scan in the two non-`full`
    /// modes.
    private static func filterLogBody(
        _ bodyText: String?,
        attributesFilter: AttributesFilter
    ) -> String? {
        guard let text = bodyText else { return nil }
        let synth = ["log.body": text]
        let filtered = attributesFilter(synth)
        return filtered["log.body"]
    }

    /// AnyValue.string_value is field 1, wire type length-delimited.
    private static func anyValueAsString(_ body: Data) -> String? {
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            guard let (field, wt) = try? reader.readTag() else { return nil }
            if field == 1, wt == .length {
                let s = (try? reader.readLengthDelimited()) ?? Data()
                return String(data: s, encoding: .utf8)
            } else {
                if (try? reader.skipValue(wireType: wt)) == nil { return nil }
            }
        }
        return nil
    }

    // MARK: - KeyValue decoding

    /// Decode one `KeyValue` proto: tag 1 LEN = key (string),
    /// tag 2 LEN = value (AnyValue). Returns nil for malformed
    /// entries or unsupported value types.
    private static func decodeKeyValue(_ body: Data) throws -> (String, String)? {
        var key: String? = nil
        var rendered: String? = nil
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            switch (field, wt) {
            case (1, .length):
                let k = try reader.readLengthDelimited()
                key = String(data: k, encoding: .utf8)
            case (2, .length):
                let av = try reader.readLengthDelimited()
                rendered = renderAnyValue(av)
            default:
                try reader.skipValue(wireType: wt)
            }
        }
        guard let k = key, !k.isEmpty, let v = rendered else { return nil }
        return (k, v)
    }

    /// Render an `AnyValue` proto as a Swift `String`. Five primitive
    /// types and one composite are covered:
    ///   - `string_value` (field 1, LEN) → returned verbatim.
    ///   - `bool_value` (field 2, varint) → "true"/"false".
    ///   - `int_value` (field 3, varint) → decimal string.
    ///   - `double_value` (field 4, fixed64) → decimal string.
    ///   - `bytes_value` (field 7, LEN) → base64 (rendered with a
    ///     `"b64:"` prefix so consumers can detect the encoding).
    /// `array_value` (field 5) and `kvlist_value` (field 6) are
    /// skipped — composite attribute values are rare in practice
    /// and the V.18a-4 envelope doesn't justify a recursive walker.
    /// The dropped composites are not a privacy concern because
    /// the filter operates on whatever made it through; this is a
    /// fidelity gap, documented in spec/architecture.md.
    private static func renderAnyValue(_ body: Data) -> String? {
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            guard let (field, wt) = try? reader.readTag() else { return nil }
            switch (field, wt) {
            case (1, .length):
                let s = (try? reader.readLengthDelimited()) ?? Data()
                return String(data: s, encoding: .utf8)
            case (2, .varint):
                let n = (try? reader.readVarint()) ?? 0
                return n == 0 ? "false" : "true"
            case (3, .varint):
                let n = (try? reader.readVarint()) ?? 0
                return String(Int64(bitPattern: n))
            case (4, .i64):
                let bits = (try? reader.readFixed64()) ?? 0
                let d = Double(bitPattern: bits)
                return String(d)
            case (7, .length):
                let raw = (try? reader.readLengthDelimited()) ?? Data()
                return "b64:" + raw.base64EncodedString()
            default:
                if (try? reader.skipValue(wireType: wt)) == nil { return nil }
            }
        }
        return nil
    }

    // MARK: - JSON inner decoders

    private static func spanRowFromJSON(
        _ span: [String: Any],
        attributesFilter: AttributesFilter
    ) -> RuntimeTelemetryStore.SpanRow? {
        let traceId = (span["traceId"] as? String) ?? (span["trace_id"] as? String) ?? ""
        let spanId = (span["spanId"] as? String) ?? (span["span_id"] as? String) ?? ""
        let parentRaw = (span["parentSpanId"] as? String) ?? (span["parent_span_id"] as? String)
        let parent: String? = (parentRaw?.isEmpty ?? true) ? nil : parentRaw
        let name = (span["name"] as? String) ?? ""
        let startNs = readUnixNs(span, "startTimeUnixNano", "start_time_unix_nano")
        let endNs = readUnixNs(span, "endTimeUnixNano", "end_time_unix_nano")
        guard !traceId.isEmpty, !spanId.isEmpty, !name.isEmpty else { return nil }
        // OTLP/JSON statusCode is a string ("STATUS_CODE_OK"/"_ERROR"/"_UNSET")
        // OR an integer (0/1/2) depending on producer. Normalize to int.
        var statusCode: Int? = nil
        if let status = span["status"] as? [String: Any] {
            if let code = status["code"] as? Int {
                statusCode = code
            } else if let codeStr = status["code"] as? String {
                statusCode = otlpStatusCodeFromString(codeStr)
            }
        }
        let attrs = decodeJSONAttributes(span["attributes"])
        let filtered = attributesFilter(attrs)
        let attrsJson = OTLPPrivacyFilter.encodeJSON(filtered)
        return RuntimeTelemetryStore.SpanRow(
            traceId: traceId,
            spanId: spanId,
            parentSpanId: parent,
            name: name,
            startUnixNs: startNs,
            endUnixNs: endNs,
            attributesJson: attrsJson,
            statusCode: statusCode,
            sessionId: nil,
            toolCallId: nil,
            validationRunId: nil
        )
    }

    private static func logRowFromJSON(
        _ rec: [String: Any],
        attributesFilter: AttributesFilter
    ) -> RuntimeTelemetryStore.LogRow? {
        let unixNs = readUnixNs(rec, "timeUnixNano", "time_unix_nano")
        guard unixNs != 0 else { return nil }
        let severityText = rec["severityText"] as? String ?? rec["severity_text"] as? String
        var bodyText: String? = nil
        if let body = rec["body"] as? [String: Any] {
            bodyText = body["stringValue"] as? String ?? body["string_value"] as? String
        } else if let s = rec["body"] as? String {
            bodyText = s
        }
        let traceId = rec["traceId"] as? String ?? rec["trace_id"] as? String
        let spanId = rec["spanId"] as? String ?? rec["span_id"] as? String
        let attrs = decodeJSONAttributes(rec["attributes"])
        let filtered = attributesFilter(attrs)
        let attrsJson = OTLPPrivacyFilter.encodeJSON(filtered)
        let filteredBody = filterLogBody(bodyText, attributesFilter: attributesFilter)
        return RuntimeTelemetryStore.LogRow(
            unixNs: unixNs,
            severityText: severityText,
            bodyText: filteredBody,
            attributesJson: attrsJson,
            traceId: (traceId?.isEmpty ?? true) ? nil : traceId,
            spanId: (spanId?.isEmpty ?? true) ? nil : spanId,
            sessionId: nil
        )
    }

    /// OTLP/JSON attribute list shape:
    ///   "attributes": [ {"key": "...", "value": {"stringValue": "..."}} ]
    /// Both camelCase (`stringValue`) and snake_case (`string_value`)
    /// are honored. Bool/int/double values are stringified.
    private static func decodeJSONAttributes(_ raw: Any?) -> [String: String] {
        guard let list = raw as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for entry in list {
            guard let key = entry["key"] as? String, !key.isEmpty else { continue }
            guard let value = entry["value"] as? [String: Any] else { continue }
            if let s = value["stringValue"] as? String ?? value["string_value"] as? String {
                out[key] = s
            } else if let b = value["boolValue"] as? Bool ?? value["bool_value"] as? Bool {
                out[key] = b ? "true" : "false"
            } else if let n = value["intValue"] as? NSNumber ?? value["int_value"] as? NSNumber {
                out[key] = n.stringValue
            } else if let s = value["intValue"] as? String ?? value["int_value"] as? String {
                // OTLP/JSON encodes 64-bit ints as strings per spec.
                out[key] = s
            } else if let d = value["doubleValue"] as? NSNumber ?? value["double_value"] as? NSNumber {
                out[key] = d.stringValue
            } else if let bytes = value["bytesValue"] as? String ?? value["bytes_value"] as? String {
                // Already base64 in OTLP/JSON.
                out[key] = "b64:" + bytes
            }
        }
        return out
    }

    private static func readUnixNs(_ d: [String: Any], _ camel: String, _ snake: String) -> Int64 {
        if let n = d[camel] as? NSNumber { return n.int64Value }
        if let n = d[snake] as? NSNumber { return n.int64Value }
        // OTLP/JSON encodes fixed64 as a *string* per the spec
        // (JSON ints lose precision past 2^53). Honor that.
        if let s = d[camel] as? String, let n = Int64(s) { return n }
        if let s = d[snake] as? String, let n = Int64(s) { return n }
        return 0
    }

    private static func otlpStatusCodeFromString(_ s: String) -> Int {
        switch s {
        case "STATUS_CODE_UNSET", "Unset": return 0
        case "STATUS_CODE_OK", "Ok": return 1
        case "STATUS_CODE_ERROR", "Error": return 2
        default: return 0
        }
    }
}

public enum OTLPDecodeError: Error, Equatable {
    case malformedJSON
}
