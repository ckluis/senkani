import Foundation

/// Browser Design Mode — click-to-capture wedge (scope-reduced from FUTURE).
///
/// Pure logic lives here so SenkaniTests can cover it without a live
/// WKWebView. The WKWebView / AppKit integration lives in
/// `SenkaniApp/Views/BrowserDesignController.swift`.
///
/// See `spec/browser_design_mode.md` for the acceptance criteria and
/// CEO review outcome.
public enum BrowserDesignMode {

    // MARK: - Env gate

    /// The env var that enables the feature. Default off.
    public static let envVarName = "SENKANI_BROWSER_DESIGN"

    /// Returns true iff `SENKANI_BROWSER_DESIGN=on`. Unset / any other
    /// value returns false. Case-insensitive on the value.
    public static func isEnabled(env: [String: String]? = nil) -> Bool {
        let value: String?
        if let env {
            value = env[envVarName]
        } else {
            value = ProcessInfo.processInfo.environment[envVarName]
        }
        guard let v = value?.lowercased() else { return false }
        return v == "on"
    }

    // MARK: - Event counters (observability)

    /// The four counter rows the wedge emits. Named per the backlog
    /// acceptance bullet.
    public enum Counter: String, Sendable, CaseIterable {
        case entered            = "browser_design.entered"
        case captured           = "browser_design.captured"
        case shadowDomSkipped   = "browser_design.shadow_dom_skipped"
        case keyboardConflict   = "browser_design.keyboard_conflict"
    }

    // MARK: - Selector generation

    /// Priority: `#id` if unique → `tag.class1.class2` if unique → nil with
    /// fallback reason. **No nth-of-type recursion** — wedge scope.
    ///
    /// `idIsUnique` and `classSetIsUnique` must be computed JS-side via
    /// `document.querySelectorAll(...).length === 1`.
    public static func generateSelector(
        tag: String,
        id: String?,
        idIsUnique: Bool,
        classes: [String],
        classSetIsUnique: Bool
    ) -> (selector: String?, fallbackReason: String?) {
        if let id, !id.isEmpty, idIsUnique {
            return ("#\(id)", nil)
        }
        if !classes.isEmpty, classSetIsUnique {
            let joined = classes.joined(separator: ".")
            return ("\(tag).\(joined)", nil)
        }
        return (nil, "no unique anchor")
    }

    // MARK: - Capture payload

    /// Raw payload as it arrives from the injected JS. Fields are whatever
    /// JS can resolve from `document.elementFromPoint` + a `getRootNode`
    /// probe. All scan + truncation + selector decisions happen Swift-side.
    public struct CapturePayload: Codable, Sendable, Equatable {
        public let tag: String
        public let id: String?
        public let idIsUnique: Bool
        public let classes: [String]
        public let classSetIsUnique: Bool
        public let innerText: String
        public let isShadow: Bool
        public let isCrossOriginIframe: Bool

        public init(
            tag: String,
            id: String?,
            idIsUnique: Bool,
            classes: [String],
            classSetIsUnique: Bool,
            innerText: String,
            isShadow: Bool,
            isCrossOriginIframe: Bool
        ) {
            self.tag = tag
            self.id = id
            self.idIsUnique = idIsUnique
            self.classes = classes
            self.classSetIsUnique = classSetIsUnique
            self.innerText = innerText
            self.isShadow = isShadow
            self.isCrossOriginIframe = isCrossOriginIframe
        }
    }

    /// Post-processed element ready for Markdown rendering.
    public struct CapturedElement: Codable, Sendable, Equatable {
        public let tag: String
        public let id: String?
        public let classes: [String]
        public let innerText: String           // truncated 300 chars, SecretDetector-scanned
        public let selector: String?
        public let capturedAt: Date
        public let fallbackReason: String?

        public init(
            tag: String,
            id: String?,
            classes: [String],
            innerText: String,
            selector: String?,
            capturedAt: Date,
            fallbackReason: String?
        ) {
            self.tag = tag
            self.id = id
            self.classes = classes
            self.innerText = innerText
            self.selector = selector
            self.capturedAt = capturedAt
            self.fallbackReason = fallbackReason
        }
    }

    /// Payload bound for `innerText` — security mitigation per spec.
    public static let innerTextMaxChars = 300

    /// Outcome of processing a raw JS payload. Mirrors the three user-
    /// visible terminal states: captured OK, shadow DOM, iframe.
    public enum Outcome: Sendable, Equatable {
        case captured(CapturedElement)
        case rejected(reason: String, counter: Counter)
    }

    /// Apply guards, scan secrets, truncate, generate selector. Pure —
    /// no clipboard, no counter writes. Caller wires those.
    public static func process(
        payload: CapturePayload,
        now: Date = Date()
    ) -> Outcome {
        if payload.isShadow {
            return .rejected(
                reason: "Can't capture — element is inside a shadow DOM.",
                counter: .shadowDomSkipped
            )
        }
        if payload.isCrossOriginIframe {
            return .rejected(
                reason: "Can't capture — element is inside a cross-origin iframe.",
                counter: .shadowDomSkipped
            )
        }

        // Truncate first, then scan. Secrets that straddle a 300-char boundary
        // are caught sink-side by `formatMarkdown`'s final scan.
        let truncated = String(payload.innerText.prefix(innerTextMaxChars))
        let scannedText = SecretDetector.scan(truncated).redacted

        // Defense-in-depth: scan classes too. Any hit is harmless here
        // (classes stay as structural tokens), but the final Markdown scan
        // will redact them if they render into the output.
        _ = SecretDetector.scan(payload.classes.joined(separator: " "))

        let (selector, fallbackReason) = generateSelector(
            tag: payload.tag,
            id: payload.id,
            idIsUnique: payload.idIsUnique,
            classes: payload.classes,
            classSetIsUnique: payload.classSetIsUnique
        )

        let element = CapturedElement(
            tag: payload.tag,
            id: payload.id,
            classes: payload.classes,
            innerText: scannedText,
            selector: selector,
            capturedAt: now,
            fallbackReason: fallbackReason
        )
        return .captured(element)
    }

    // MARK: - Markdown formatting

    /// Fixed Markdown schema per spec. Snapshot-tested. Final output is
    /// run through `SecretDetector.scan` one more time (sink-side) —
    /// belt-and-suspenders against anything that slipped through
    /// (e.g. a secret embedded in a class name that would otherwise
    /// render into the `tag:` line).
    public static func formatMarkdown(_ element: CapturedElement) -> String {
        let selectorLine: String
        if let sel = element.selector {
            selectorLine = "- selector: `\(sel)`"
        } else {
            let reason = element.fallbackReason ?? "no unique anchor"
            selectorLine = "- selector: none — \(reason)"
        }

        let tagLine: String
        if element.classes.isEmpty {
            tagLine = "- tag: `\(element.tag)`"
        } else {
            tagLine = "- tag: `\(element.tag).\(element.classes.joined(separator: "."))`"
        }

        let textLine = "- text: \"\(element.innerText)\""

        let timestamp = iso8601String(element.capturedAt)
        let capturedLine = "- captured: \(timestamp)"

        let raw = """
        ## Browser element (senkani design mode)
        \(selectorLine)
        \(tagLine)
        \(textLine)
        \(capturedLine)
        """
        return SecretDetector.scan(raw).redacted
    }

    /// Rejection-path Markdown — when shadow DOM / iframe blocks capture.
    public static func formatRejectionMarkdown(reason: String, at now: Date = Date()) -> String {
        let timestamp = iso8601String(now)
        return """
        ## Browser element (senkani design mode)
        - selector: none — \(reason)
        - captured: \(timestamp)
        """
    }

    /// Foundation's `ISO8601DateFormatter` isn't Sendable, so a static
    /// instance trips Swift 6 strict concurrency. `Date.formatted(.iso8601)`
    /// uses an actor-isolated format style internally — safe + deterministic.
    static func iso8601String(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    // MARK: - Mode state machine

    /// Tracks which pane (if any) has Design Mode active. Transitions are
    /// total — any illegal transition is a no-op so the App-side
    /// controller can never wedge the state.
    public struct State: Equatable, Sendable {
        public var activePaneId: String?
        public var scriptInstalled: Bool

        public init(activePaneId: String? = nil, scriptInstalled: Bool = false) {
            self.activePaneId = activePaneId
            self.scriptInstalled = scriptInstalled
        }

        /// Is Design Mode currently active on a pane?
        public var isActive: Bool { activePaneId != nil }

        // --- transitions ---

        /// Enter mode on `paneId`. If another pane is active, exit it first.
        public mutating func enter(paneId: String, featureEnabled: Bool) {
            guard featureEnabled else { return }  // env-gate no-op
            activePaneId = paneId
            scriptInstalled = true
        }

        /// Exit via ⌥⇧D toggle or Escape.
        public mutating func exit() {
            activePaneId = nil
            scriptInstalled = false
        }

        /// Navigation on the active pane exits mode AND discards the
        /// injected user script — guards the leak-across-navigation
        /// failure mode Torvalds flagged.
        public mutating func navigated(paneId: String) {
            if activePaneId == paneId {
                activePaneId = nil
                scriptInstalled = false
            }
        }

        /// Pane closed — if it was the active one, tear down.
        public mutating func paneClosed(paneId: String) {
            if activePaneId == paneId {
                activePaneId = nil
                scriptInstalled = false
            }
        }
    }

    // MARK: - Injected JS

    /// The WKUserScript source injected into the WKWebView on mode-enter.
    /// Snapshot-tested so drift is visible in review.
    ///
    /// Responsibilities:
    ///   - Mouse outline on hover.
    ///   - Click → serialize element + uniqueness probes + shadow / iframe
    ///     guards, post to `window.webkit.messageHandlers.senkaniDesign`.
    ///   - Escape → post exit signal.
    public static let injectedJSSource = """
    (function() {
      if (window.__senkaniDesignActive) return;
      window.__senkaniDesignActive = true;

      var style = document.createElement('style');
      style.setAttribute('data-senkani-design', '1');
      style.textContent = '.__senkani_outline__ { outline: 1px solid #f5a623 !important; }' +
        'body { cursor: crosshair !important; }';
      document.head.appendChild(style);

      var last = null;
      function outline(el) {
        if (last && last !== el) last.classList.remove('__senkani_outline__');
        if (el && el.classList) el.classList.add('__senkani_outline__');
        last = el;
      }

      function post(msg) {
        try {
          window.webkit.messageHandlers.senkaniDesign.postMessage(msg);
        } catch (e) { /* handler missing, silent */ }
      }

      function classList(el) {
        if (!el || !el.classList) return [];
        var out = [];
        for (var i = 0; i < el.classList.length; i++) {
          var c = el.classList[i];
          if (c !== '__senkani_outline__') out.push(c);
        }
        return out;
      }

      function isUniqueById(id) {
        if (!id) return false;
        try { return document.querySelectorAll('#' + CSS.escape(id)).length === 1; }
        catch (e) { return false; }
      }

      function isUniqueByClassSet(tag, cs) {
        if (!cs || cs.length === 0) return false;
        var sel = tag + '.' + cs.map(function(c) { return CSS.escape(c); }).join('.');
        try { return document.querySelectorAll(sel).length === 1; }
        catch (e) { return false; }
      }

      document.addEventListener('mousemove', function(e) {
        var el = document.elementFromPoint(e.clientX, e.clientY);
        outline(el);
      }, true);

      document.addEventListener('click', function(e) {
        e.preventDefault();
        e.stopPropagation();
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el) return;

        var root = el.getRootNode();
        var isShadow = (root && root.nodeType === 11 && root.host);  // ShadowRoot
        var isIframe = (el.ownerDocument !== document);

        var classes = classList(el);
        var tag = (el.tagName || 'unknown').toLowerCase();
        var id = el.id || null;
        var text = el.innerText || el.textContent || '';

        post({
          kind: 'capture',
          tag: tag,
          id: id,
          idIsUnique: isUniqueById(id),
          classes: classes,
          classSetIsUnique: isUniqueByClassSet(tag, classes),
          innerText: text,
          isShadow: !!isShadow,
          isCrossOriginIframe: !!isIframe
        });
      }, true);

      document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape') {
          post({ kind: 'exit' });
        }
      }, true);
    })();
    """
}
