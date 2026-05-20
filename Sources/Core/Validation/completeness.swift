import Foundation

/// Browser-measured completeness payload. The TS runner walks the DOM in
/// `page.evaluate(...)`, HEAD-probes internal links via `page.request.fetch`,
/// and emits this shape; the Swift evaluator consumes it.
public struct CompletenessMeasurement: Codable, Sendable, Equatable {
    public let title: String?
    public let metaDescription: String?
    public let internalLinks: [InternalLink]
    public let images: [ImageElement]

    public init(
        title: String?,
        metaDescription: String?,
        internalLinks: [InternalLink],
        images: [ImageElement]
    ) {
        self.title = title
        self.metaDescription = metaDescription
        self.internalLinks = internalLinks
        self.images = images
    }

    public struct InternalLink: Codable, Sendable, Equatable {
        public let href: String
        public let statusCode: Int?

        public init(href: String, statusCode: Int? = nil) {
            self.href = href
            self.statusCode = statusCode
        }

        enum CodingKeys: String, CodingKey {
            case href
            case statusCode = "status_code"
        }
    }

    public struct ImageElement: Codable, Sendable, Equatable {
        public let src: String
        public let alt: String?

        public init(src: String, alt: String? = nil) {
            self.src = src
            self.alt = alt
        }
    }

    enum CodingKeys: String, CodingKey {
        case title
        case metaDescription = "meta_description"
        case internalLinks = "internal_links"
        case images
    }
}

/// Reserved for U.2b-axes assertion overrides. U.2a-2a ships no expected-
/// value surface for completeness (every assertion is binary presence /
/// scoped-failure-count); the struct exists so the call signature stays
/// stable when U.2b-axes adds per-call overrides.
public struct CompletenessExpected: Codable, Sendable, Equatable {
    public init() {}
}

/// Completeness axis evaluator. Pure function over a `CompletenessMeasurement`
/// payload. Returns three `AssertionResult` rows:
///
///   - `completeness.title_meta` — `<title>` non-empty AND
///     `<meta name="description">` present + non-empty.
///   - `completeness.internal_links_resolve` — every same-origin link
///     returned a status code < 400 (404 / 500 / network errors fail).
///   - `completeness.img_alt` — every `<img>` element has a non-empty
///     `alt` attribute (a11y baseline).
public enum CompletenessAxis {
    public static func evaluate(
        measurement: CompletenessMeasurement,
        expected: CompletenessExpected? = nil
    ) -> [AssertionResult] {
        _ = expected  // reserved for U.2b-axes
        var results: [AssertionResult] = []

        let title = (measurement.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = (measurement.metaDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let titleMetaPass = !title.isEmpty && !meta.isEmpty
        let titleMetaAdvisory: String?
        if titleMetaPass {
            titleMetaAdvisory = nil
        } else {
            var missing: [String] = []
            if title.isEmpty { missing.append("<title>") }
            if meta.isEmpty { missing.append("<meta name=\"description\">") }
            titleMetaAdvisory = "missing or empty: \(missing.joined(separator: ", "))"
        }
        results.append(AssertionResult(
            assertionId: "completeness.title_meta",
            passed: titleMetaPass,
            measured: nil,
            threshold: nil,
            advisory: titleMetaAdvisory
        ))

        let badLinks = measurement.internalLinks.filter { link in
            guard let code = link.statusCode else { return true }  // network error treated as fail
            return code >= 400
        }
        let linksPass = badLinks.isEmpty
        let linksAdvisory: String?
        if linksPass {
            linksAdvisory = nil
        } else {
            let preview = badLinks.prefix(5).map { l in
                "\(l.href) (\(l.statusCode.map(String.init) ?? "no response"))"
            }.joined(separator: ", ")
            linksAdvisory = "\(badLinks.count) internal link(s) failed to resolve: \(preview)"
        }
        results.append(AssertionResult(
            assertionId: "completeness.internal_links_resolve",
            passed: linksPass,
            measured: measurement.internalLinks.count,
            threshold: nil,
            advisory: linksAdvisory
        ))

        let altMissing = measurement.images.filter { img in
            (img.alt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let altPass = altMissing.isEmpty
        let altAdvisory: String?
        if altPass {
            altAdvisory = nil
        } else {
            let preview = altMissing.prefix(5).map(\.src).joined(separator: ", ")
            altAdvisory = "\(altMissing.count) <img> element(s) missing or empty alt attribute: \(preview)"
        }
        results.append(AssertionResult(
            assertionId: "completeness.img_alt",
            passed: altPass,
            measured: measurement.images.count,
            threshold: nil,
            advisory: altAdvisory
        ))

        return results
    }
}
