import Testing
import Foundation
@testable import Core

/// Browser Design Mode wedge — pure-logic coverage.
///
/// Acceptance mapping:
///   1. Id-anchor selector          → `idAnchorSelector`
///   2. Class-anchor selector       → `classAnchorSelector`
///   3. No-anchor fallback          → `noAnchorFallback`
///   4. Shadow DOM guard            → `shadowDomGuard`
///   5. SecretDetector sink         → `secretDetectorRedactsInnerText`
///   6. Markdown snapshot           → `markdownSnapshot`
///   7. Mode lifecycle              → `modeLifecycleOnNavigationAndClose`
///   8. Env-var gate                → `envVarGate`
///   9. Scan classes (defense)      → `secretInClassNameRedactedSinkSide`
///
/// Intentional deferrals (gated on usage data per spec):
///   - Live WKWebView end-to-end — covered in `tools/soak/manual-log.md`.
@Suite("BrowserDesignMode wedge")
struct BrowserDesignModeTests {

    // MARK: - Selector generation

    @Test("Id-anchor selector wins when id is unique")
    func idAnchorSelector() {
        let out = BrowserDesignMode.generateSelector(
            tag: "button",
            id: "submit",
            idIsUnique: true,
            classes: ["primary", "lg"],
            classSetIsUnique: true
        )
        #expect(out.selector == "#submit")
        #expect(out.fallbackReason == nil)
    }

    @Test("Class-anchor selector when id is missing but class set is unique")
    func classAnchorSelector() {
        let out = BrowserDesignMode.generateSelector(
            tag: "div",
            id: nil,
            idIsUnique: false,
            classes: ["uniq"],
            classSetIsUnique: true
        )
        #expect(out.selector == "div.uniq")
        #expect(out.fallbackReason == nil)
    }

    @Test("Non-unique id falls through to class set")
    func nonUniqueIdFallsThroughToClass() {
        let out = BrowserDesignMode.generateSelector(
            tag: "span",
            id: "dup",
            idIsUnique: false,
            classes: ["only-one"],
            classSetIsUnique: true
        )
        #expect(out.selector == "span.only-one")
        #expect(out.fallbackReason == nil)
    }

    @Test("No-anchor fallback emits nil selector + reason")
    func noAnchorFallback() {
        let out = BrowserDesignMode.generateSelector(
            tag: "span",
            id: nil,
            idIsUnique: false,
            classes: [],
            classSetIsUnique: false
        )
        #expect(out.selector == nil)
        #expect(out.fallbackReason == "no unique anchor")
    }

    // MARK: - Shadow DOM / iframe guards

    @Test("Shadow DOM payload rejected with clear toast reason")
    func shadowDomGuard() {
        let payload = BrowserDesignMode.CapturePayload(
            tag: "button",
            id: "inner",
            idIsUnique: true,
            classes: [],
            classSetIsUnique: false,
            innerText: "Click me",
            isShadow: true,
            isCrossOriginIframe: false
        )
        let outcome = BrowserDesignMode.process(payload: payload)
        switch outcome {
        case .rejected(let reason, let counter):
            #expect(reason.contains("shadow DOM"))
            #expect(counter == .shadowDomSkipped)
        case .captured:
            Issue.record("Expected shadow-DOM rejection")
        }
    }

    @Test("Cross-origin iframe rejected")
    func iframeGuard() {
        let payload = BrowserDesignMode.CapturePayload(
            tag: "a",
            id: nil,
            idIsUnique: false,
            classes: ["btn"],
            classSetIsUnique: false,
            innerText: "Open",
            isShadow: false,
            isCrossOriginIframe: true
        )
        let outcome = BrowserDesignMode.process(payload: payload)
        guard case .rejected(let reason, let counter) = outcome else {
            Issue.record("Expected iframe rejection"); return
        }
        #expect(reason.contains("iframe"))
        #expect(counter == .shadowDomSkipped)
    }

    // MARK: - SecretDetector

    @Test("SecretDetector redacts token inside innerText before Markdown emit")
    func secretDetectorRedactsInnerText() {
        let raw = "sk_live_1234567890abcdef1234567890ab"
        let payload = BrowserDesignMode.CapturePayload(
            tag: "code",
            id: "snippet",
            idIsUnique: true,
            classes: [],
            classSetIsUnique: false,
            innerText: raw,
            isShadow: false,
            isCrossOriginIframe: false
        )
        guard case .captured(let element) = BrowserDesignMode.process(payload: payload) else {
            Issue.record("Expected successful capture"); return
        }
        #expect(!element.innerText.contains(raw))
        #expect(element.innerText.contains("[REDACTED:"))
        let md = BrowserDesignMode.formatMarkdown(element)
        #expect(!md.contains(raw))
        #expect(md.contains("[REDACTED:"))
    }

    @Test("Secret inside a class name is redacted in the final Markdown (sink-side)")
    func secretInClassNameRedactedSinkSide() {
        // Class name carrying a Stripe-shaped secret. Structural tokens aren't
        // rewritten in the CapturedElement (selectors would break), but the
        // final Markdown sink-side scan catches it.
        let poisonedClass = "sk_live_abcdefghijklmnopqrstuvwxyzABCDEF"
        let payload = BrowserDesignMode.CapturePayload(
            tag: "div",
            id: nil,
            idIsUnique: false,
            classes: [poisonedClass],
            classSetIsUnique: true,
            innerText: "ok",
            isShadow: false,
            isCrossOriginIframe: false
        )
        guard case .captured(let element) = BrowserDesignMode.process(payload: payload) else {
            Issue.record("Expected successful capture"); return
        }
        let md = BrowserDesignMode.formatMarkdown(element)
        #expect(!md.contains(poisonedClass), "Class-name secret leaked into Markdown output")
        #expect(md.contains("[REDACTED:"))
    }

    @Test("innerText truncated at 300 chars")
    func innerTextTruncation() {
        let long = String(repeating: "a", count: 500)
        let payload = BrowserDesignMode.CapturePayload(
            tag: "p",
            id: nil,
            idIsUnique: false,
            classes: [],
            classSetIsUnique: false,
            innerText: long,
            isShadow: false,
            isCrossOriginIframe: false
        )
        guard case .captured(let element) = BrowserDesignMode.process(payload: payload) else {
            Issue.record("Expected capture"); return
        }
        #expect(element.innerText.count <= BrowserDesignMode.innerTextMaxChars)
    }

    // MARK: - Markdown snapshot

    @Test("Markdown snapshot is byte-stable against a fixed CapturedElement")
    func markdownSnapshot() {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z
        let element = BrowserDesignMode.CapturedElement(
            tag: "button",
            id: "submit",
            classes: ["primary", "lg"],
            innerText: "Submit form",
            selector: "#submit",
            capturedAt: fixed,
            fallbackReason: nil
        )
        let md = BrowserDesignMode.formatMarkdown(element)
        let expected = """
        ## Browser element (senkani design mode)
        - selector: `#submit`
        - tag: `button.primary.lg`
        - text: "Submit form"
        - captured: 2023-11-14T22:13:20Z
        """
        #expect(md == expected)
    }

    @Test("Markdown with no anchor renders selector-none line")
    func markdownFallbackLine() {
        let element = BrowserDesignMode.CapturedElement(
            tag: "span",
            id: nil,
            classes: [],
            innerText: "hello",
            selector: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fallbackReason: "no unique anchor"
        )
        let md = BrowserDesignMode.formatMarkdown(element)
        #expect(md.contains("- selector: none — no unique anchor"))
        #expect(md.contains("- tag: `span`"))
    }

    // MARK: - State machine — lifecycle

    @Test("Mode lifecycle: enter → navigate → script removed, mode exited")
    func modeLifecycleOnNavigationAndClose() {
        var s = BrowserDesignMode.State()
        #expect(!s.isActive)
        #expect(!s.scriptInstalled)

        s.enter(paneId: "pane-A", featureEnabled: true)
        #expect(s.isActive)
        #expect(s.activePaneId == "pane-A")
        #expect(s.scriptInstalled)

        // Navigation on the active pane MUST discard the script and exit —
        // guards Torvalds' leak-across-navigation flag.
        s.navigated(paneId: "pane-A")
        #expect(!s.isActive)
        #expect(s.activePaneId == nil)
        #expect(!s.scriptInstalled)

        // Re-enter, then close the pane.
        s.enter(paneId: "pane-B", featureEnabled: true)
        #expect(s.isActive)
        s.paneClosed(paneId: "pane-B")
        #expect(!s.isActive)
        #expect(!s.scriptInstalled)
    }

    @Test("Navigation on a NON-active pane is a no-op")
    func navigationOnInactivePaneNoops() {
        var s = BrowserDesignMode.State()
        s.enter(paneId: "pane-A", featureEnabled: true)
        s.navigated(paneId: "pane-B")   // different pane
        #expect(s.isActive)
        #expect(s.activePaneId == "pane-A")
    }

    // MARK: - Env-var gate

    @Test("Env-var gate: unset = disabled, off = disabled, on = enabled")
    func envVarGate() {
        #expect(BrowserDesignMode.isEnabled(env: [:]) == false)
        #expect(BrowserDesignMode.isEnabled(env: ["SENKANI_BROWSER_DESIGN": "off"]) == false)
        #expect(BrowserDesignMode.isEnabled(env: ["SENKANI_BROWSER_DESIGN": "1"]) == false)
        #expect(BrowserDesignMode.isEnabled(env: ["SENKANI_BROWSER_DESIGN": "on"]) == true)
        #expect(BrowserDesignMode.isEnabled(env: ["SENKANI_BROWSER_DESIGN": "ON"]) == true)
        // State.enter respects the gate: featureEnabled:false is a no-op.
        var s = BrowserDesignMode.State()
        s.enter(paneId: "pane-X", featureEnabled: false)
        #expect(!s.isActive)
        #expect(!s.scriptInstalled)
    }

    // MARK: - Counters vocabulary

    @Test("All four acceptance counters are declared")
    func allCountersDeclared() {
        let names = Set(BrowserDesignMode.Counter.allCases.map(\.rawValue))
        #expect(names == [
            "browser_design.entered",
            "browser_design.captured",
            "browser_design.shadow_dom_skipped",
            "browser_design.keyboard_conflict",
        ])
    }

    // MARK: - Injected JS sanity

    @Test("Injected JS bundle exposes message handler name + escape hook")
    func injectedJsSanity() {
        let js = BrowserDesignMode.injectedJSSource
        #expect(js.contains("webkit.messageHandlers.senkaniDesign"))
        #expect(js.contains("document.elementFromPoint"))
        #expect(js.contains("getRootNode"))
        #expect(js.contains("Escape"))
        // Re-entrancy guard so a re-installed script doesn't double-bind.
        #expect(js.contains("__senkaniDesignActive"))
    }
}
