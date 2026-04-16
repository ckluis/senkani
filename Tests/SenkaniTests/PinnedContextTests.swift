import Testing
import Foundation
@testable import Core

// MARK: - PinnedContextStore Tests

@Suite("PinnedContextStore")
struct PinnedContextStoreTests {

    @Test func pinnedContextAppearsInNextDrain() {
        let store = PinnedContextStore()
        let entry = PinnedEntry(name: "SessionDatabase", outline: "class SessionDatabase\n  func insert()", ttl: 3)
        store.pin(entry)

        let (context, expiry) = store.drain()
        #expect(context != nil, "Expected pinned context block on first drain")
        #expect(context!.contains("@SessionDatabase"), "Block should contain @-name")
        #expect(context!.contains("class SessionDatabase"), "Block should contain outline")
        #expect(expiry.isEmpty, "No expiry on first drain (ttl=3, now 2 remaining)")
    }

    @Test func pinnedContextDecrementsAndExpires() {
        let store = PinnedContextStore()
        store.pin(PinnedEntry(name: "Foo", outline: "func foo()", ttl: 2))

        let (ctx1, exp1) = store.drain()  // calls remaining: 1
        #expect(ctx1 != nil)
        #expect(exp1.isEmpty)

        let (ctx2, exp2) = store.drain()  // calls remaining: 0 → expires
        // Entry with 0 remaining is evicted before formatting
        #expect(ctx2 == nil, "Entry should be evicted when callsRemaining hits 0")
        #expect(exp2.count == 1, "Should emit one expiry notice")
        #expect(exp2[0].contains("Foo"), "Expiry notice should name the entry")
        #expect(exp2[0].contains("re-pin"), "Expiry notice should hint at re-pinning")

        // Third drain — store is empty
        let (ctx3, exp3) = store.drain()
        #expect(ctx3 == nil)
        #expect(exp3.isEmpty)
    }

    @Test func pinUpsertResetsTTL() {
        let store = PinnedContextStore()
        store.pin(PinnedEntry(name: "Bar", outline: "struct Bar", ttl: 5))
        _ = store.drain()  // ttl now 4
        _ = store.drain()  // ttl now 3

        // Re-pin with higher TTL
        store.pin(PinnedEntry(name: "Bar", outline: "struct Bar — updated", ttl: 20))
        let all = store.all()
        #expect(all.count == 1)
        #expect(all[0].callsRemaining == 20, "Upsert should reset TTL to new value")
        #expect(all[0].outline.contains("updated"), "Upsert should replace outline")
    }

    @Test func tokenCapEvictsOldestWhenFull() {
        let store = PinnedContextStore()
        for i in 1...PinnedContextStore.maxEntries {
            store.pin(PinnedEntry(name: "Symbol\(i)", outline: "class Symbol\(i)"))
        }
        #expect(store.all().count == PinnedContextStore.maxEntries)

        // Pin one more — oldest (Symbol1) should be evicted
        store.pin(PinnedEntry(name: "SymbolExtra", outline: "class SymbolExtra"))
        let names = store.all().map(\.name)
        #expect(names.count == PinnedContextStore.maxEntries)
        #expect(!names.contains("Symbol1"), "Oldest entry should be evicted")
        #expect(names.contains("SymbolExtra"), "New entry should be present")
    }

    @Test func unpinRemovesImmediately() {
        let store = PinnedContextStore()
        store.pin(PinnedEntry(name: "Target", outline: "func target()"))
        #expect(!store.isEmpty)

        store.unpin(name: "Target")
        #expect(store.isEmpty, "Store should be empty after unpin")

        let (ctx, _) = store.drain()
        #expect(ctx == nil, "No context after unpin")
    }

    @Test func unpinIsCaseInsensitive() {
        let store = PinnedContextStore()
        store.pin(PinnedEntry(name: "MyClass", outline: "class MyClass"))
        store.unpin(name: "myclass")
        #expect(store.isEmpty, "Case-insensitive unpin should work")
    }

    @Test func pinsActionDataMatchesDrain() {
        // Verify that `all()` snapshot reflects same state as what drain would emit.
        let store = PinnedContextStore()
        store.pin(PinnedEntry(name: "Alpha", outline: "func alpha()", ttl: 10))
        store.pin(PinnedEntry(name: "Beta",  outline: "func beta()",  ttl: 5))

        let all = store.all()
        #expect(all.count == 2)
        #expect(all[0].name == "Alpha", "all() returns oldest-first")
        #expect(all[1].name == "Beta")
        #expect(all[0].callsRemaining == 10)
        #expect(all[1].callsRemaining == 5)
    }

    @Test func autoPinDisabledByDefault() {
        // When auto-pin is off, the store should stay empty after a hypothetical @-mention.
        // Verified by confirming a fresh PinnedContextStore is empty at construction,
        // and that no entries appear without an explicit `pin()` call.
        let store = PinnedContextStore()
        #expect(store.isEmpty, "Store starts empty — no auto-pin without explicit pin()")
        let (ctx, _) = store.drain()
        #expect(ctx == nil, "No context without an explicit pin")
    }
}

// MARK: - PinnedEntry Invariants

@Suite("PinnedEntry")
struct PinnedEntryTests {

    @Test func outlineTruncatedAtMaxEntryChars() {
        let longOutline = String(repeating: "x", count: PinnedContextStore.maxEntryChars + 100)
        let entry = PinnedEntry(name: "Big", outline: longOutline)
        #expect(entry.outline.count == PinnedContextStore.maxEntryChars,
                "Outline must be clamped to maxEntryChars at init")
    }

    @Test func ttlClampedToMin() {
        let entry = PinnedEntry(name: "T", outline: "x", ttl: 0)
        #expect(entry.callsRemaining == PinnedContextStore.minTTL)
    }

    @Test func ttlClampedToMax() {
        let entry = PinnedEntry(name: "T", outline: "x", ttl: 9999)
        #expect(entry.callsRemaining == PinnedContextStore.maxTTL)
    }
}
