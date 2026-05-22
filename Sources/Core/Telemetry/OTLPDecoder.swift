import Foundation

/// V.18a-3 — decode OTLP `/v1/traces` and `/v1/logs` request bodies
/// into `RuntimeTelemetryStore.SpanRow` / `LogRow` payloads.
///
/// Supports both wire formats (OTLP/protobuf and OTLP/JSON). The
/// receiver dispatches by `Content-Type` header — see
/// `RuntimeTelemetryReceiver.MimeType`.
///
/// Field tags below match the OTLP proto definitions
/// (opentelemetry-proto v1.0.0). We only walk the structure deep
/// enough to extract the five SpanRow + six LogRow fields the
/// V.18a-2 store needs; unknown fields are skipped via wire type.
public enum OTLPDecoder {

    /// Decode an `ExportTraceServiceRequest` protobuf body.
    /// Returns one `SpanRow` per span across every `ResourceSpans` /
    /// `ScopeSpans` group. Raw span bytes are base64-stashed in
    /// `attributesJson` so V.18a-4 can re-parse for the privacy
    /// filter without re-shipping the receiver.
    public static func decodeTracesProtobuf(_ body: Data) throws -> [RuntimeTelemetryStore.SpanRow] {
        var rows: [RuntimeTelemetryStore.SpanRow] = []
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            // ExportTraceServiceRequest.resource_spans = 1 (repeated ResourceSpans)
            if field == 1, wt == .length {
                let rsBytes = try reader.readLengthDelimited()
                try decodeResourceSpans(rsBytes, into: &rows)
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
        return rows
    }

    /// Decode an `ExportLogsServiceRequest` protobuf body.
    public static func decodeLogsProtobuf(_ body: Data) throws -> [RuntimeTelemetryStore.LogRow] {
        var rows: [RuntimeTelemetryStore.LogRow] = []
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            if field == 1, wt == .length {
                let rlBytes = try reader.readLengthDelimited()
                try decodeResourceLogs(rlBytes, into: &rows)
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
        return rows
    }

    /// Decode an OTLP/JSON `ExportTraceServiceRequest`. The JSON
    /// representation mirrors the protobuf field names, snake_cased.
    /// Span IDs are transmitted as hex strings (no base64 quirks).
    public static func decodeTracesJSON(_ body: Data) throws -> [RuntimeTelemetryStore.SpanRow] {
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
                    if let row = spanRowFromJSON(span) {
                        rows.append(row)
                    }
                }
            }
        }
        return rows
    }

    /// Decode an OTLP/JSON `ExportLogsServiceRequest`.
    public static func decodeLogsJSON(_ body: Data) throws -> [RuntimeTelemetryStore.LogRow] {
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
                    if let row = logRowFromJSON(rec) {
                        rows.append(row)
                    }
                }
            }
        }
        return rows
    }

    // MARK: - protobuf inner decoders

    private static func decodeResourceSpans(_ body: Data, into rows: inout [RuntimeTelemetryStore.SpanRow]) throws {
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            // ResourceSpans.scope_spans = 2 (repeated ScopeSpans)
            if field == 2, wt == .length {
                let ssBytes = try reader.readLengthDelimited()
                try decodeScopeSpans(ssBytes, into: &rows)
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
    }

    private static func decodeScopeSpans(_ body: Data, into rows: inout [RuntimeTelemetryStore.SpanRow]) throws {
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            // ScopeSpans.spans = 2 (repeated Span)
            if field == 2, wt == .length {
                let spanBytes = try reader.readLengthDelimited()
                if let row = try decodeSpan(spanBytes) {
                    rows.append(row)
                }
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
    }

    private static func decodeSpan(_ body: Data) throws -> RuntimeTelemetryStore.SpanRow? {
        var traceId = Data()
        var spanId = Data()
        var parentSpanId = Data()
        var name = ""
        var startNs: UInt64 = 0
        var endNs: UInt64 = 0
        var statusCode: Int? = nil
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
        // Empty IDs also signal a malformed message; drop on the
        // floor here so the receiver can return 200 OK for the batch
        // without polluting the table.
        if traceId.isEmpty || spanId.isEmpty || name.isEmpty {
            return nil
        }
        // Stash the raw span protobuf bytes (base64) as the row's
        // attributes_json. V.18a-4 will rewrite this with the
        // metadata-only filtered payload.
        let rawB64 = body.base64EncodedString()
        let attrsJson = "{\"otlp_raw_b64\":\"\(rawB64)\"}"
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

    private static func decodeResourceLogs(_ body: Data, into rows: inout [RuntimeTelemetryStore.LogRow]) throws {
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            if field == 2, wt == .length {
                let slBytes = try reader.readLengthDelimited()
                try decodeScopeLogs(slBytes, into: &rows)
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
    }

    private static func decodeScopeLogs(_ body: Data, into rows: inout [RuntimeTelemetryStore.LogRow]) throws {
        var reader = OTLPWireReader(body)
        while !reader.isAtEnd {
            let (field, wt) = try reader.readTag()
            // ScopeLogs.log_records = 2 (repeated LogRecord)
            if field == 2, wt == .length {
                let recBytes = try reader.readLengthDelimited()
                if let row = try decodeLogRecord(recBytes) {
                    rows.append(row)
                }
            } else {
                try reader.skipValue(wireType: wt)
            }
        }
    }

    private static func decodeLogRecord(_ body: Data) throws -> RuntimeTelemetryStore.LogRow? {
        var unixNs: UInt64 = 0
        var severityText: String? = nil
        var bodyText: String? = nil
        var traceId = Data()
        var spanId = Data()
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
        let rawB64 = body.base64EncodedString()
        let attrsJson = "{\"otlp_raw_b64\":\"\(rawB64)\"}"
        return RuntimeTelemetryStore.LogRow(
            unixNs: Int64(bitPattern: unixNs),
            severityText: severityText,
            bodyText: bodyText,
            attributesJson: attrsJson,
            traceId: traceId.isEmpty ? nil : OTLPHex.encode(traceId),
            spanId: spanId.isEmpty ? nil : OTLPHex.encode(spanId),
            sessionId: nil
        )
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

    // MARK: - JSON inner decoders

    private static func spanRowFromJSON(_ span: [String: Any]) -> RuntimeTelemetryStore.SpanRow? {
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
        // Stash the original JSON span as attributes_json so V.18a-4
        // can run the privacy filter against it.
        let raw = (try? JSONSerialization.data(withJSONObject: span)) ?? Data("{}".utf8)
        let attrsJson = String(data: raw, encoding: .utf8) ?? "{}"
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

    private static func logRowFromJSON(_ rec: [String: Any]) -> RuntimeTelemetryStore.LogRow? {
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
        let raw = (try? JSONSerialization.data(withJSONObject: rec)) ?? Data("{}".utf8)
        let attrsJson = String(data: raw, encoding: .utf8) ?? "{}"
        return RuntimeTelemetryStore.LogRow(
            unixNs: unixNs,
            severityText: severityText,
            bodyText: bodyText,
            attributesJson: attrsJson,
            traceId: (traceId?.isEmpty ?? true) ? nil : traceId,
            spanId: (spanId?.isEmpty ?? true) ? nil : spanId,
            sessionId: nil
        )
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
