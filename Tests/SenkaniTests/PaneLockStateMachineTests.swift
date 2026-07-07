import Testing
import BrowserPane

/// U.2b-2 GUI child a-1 — pure-logic unit tests for the pane input-lock
/// state machine. No display, no WebKit, no main actor — the machine is
/// Foundation-only so these run headlessly under `swift test`.
@Suite("PaneLockStateMachine — U.2b-2 a-1")
struct PaneLockStateMachineTests {

    @Test("starts unlocked — URL bar + nav enabled, no banner")
    func startsUnlocked() {
        let m = PaneLockStateMachine()
        #expect(m.state == .unlocked)
        #expect(m.inputEnabled == true)
        #expect(m.bannerVisible == false)
    }

    @Test("dispatch start locks the pane — input disabled")
    func dispatchStartLocks() {
        var m = PaneLockStateMachine()
        let r = m.apply(.dispatchStarted)
        #expect(r == .success(.locked))
        #expect(m.state == .locked)
        #expect(m.inputEnabled == false)
        #expect(m.bannerVisible == false)
    }

    @Test("unlock on success — locked → unlocked, input re-enabled")
    func unlockOnSuccess() {
        var m = PaneLockStateMachine()
        m.apply(.dispatchStarted)
        let r = m.apply(.dispatchSucceeded)
        #expect(r == .success(.unlocked))
        #expect(m.state == .unlocked)
        #expect(m.inputEnabled == true)
    }

    @Test("refusal shows banner and stays locked; dismiss unlocks")
    func unlockOnDismiss() {
        var m = PaneLockStateMachine()
        m.apply(.dispatchStarted)
        let refuse = m.apply(.dispatchRefused)
        #expect(refuse == .success(.refused))
        #expect(m.bannerVisible == true)
        #expect(m.inputEnabled == false)  // still locked while banner up
        let dismiss = m.apply(.bannerDismissed)
        #expect(dismiss == .success(.unlocked))
        #expect(m.state == .unlocked)
        #expect(m.inputEnabled == true)
    }

    @Test("fail-closed: double dispatch is rejected and does not mutate state")
    func doubleDispatchRejected() {
        var m = PaneLockStateMachine()
        m.apply(.dispatchStarted)
        let r = m.apply(.dispatchStarted)
        #expect(r == .failure(.doubleDispatch))
        #expect(m.state == .locked)  // unchanged — still exactly one dispatch
    }

    @Test("fail-closed: dismiss during an active dispatch is rejected, stays locked")
    func dismissDuringActiveDispatchRejected() {
        var m = PaneLockStateMachine()
        m.apply(.dispatchStarted)
        let r = m.apply(.bannerDismissed)
        #expect(r == .failure(.dismissWhileActive))
        #expect(m.state == .locked)  // no banner to dismiss; lock intact
    }

    @Test("retry: a new dispatch may start directly from the refused/banner state")
    func retryFromRefused() {
        var m = PaneLockStateMachine()
        m.apply(.dispatchStarted)
        m.apply(.dispatchRefused)
        let r = m.apply(.dispatchStarted)
        #expect(r == .success(.locked))
        #expect(m.state == .locked)
    }
}
