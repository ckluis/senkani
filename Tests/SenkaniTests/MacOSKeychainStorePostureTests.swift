#if canImport(Security)
import Testing
import Foundation
import Security
@testable import Core

/// V.13b-1 follow-up — pin `MacOSKeychainStore`'s security-relevant accessibility
/// posture so a future refactor cannot silently weaken it.
///
/// The store deliberately writes `kSecClassGenericPassword` items with
/// `kSecAttrAccessibleAfterFirstUnlock` (NOT `WhenUnlocked` — a long-running
/// `senkani serve` must keep reading the key after the screen locks) and sets
/// NO `kSecAttrSynchronizable` (the secret is never device-synced to iCloud).
/// Before this suite that posture lived ONLY in a source comment; a refactor
/// to `WhenUnlocked` (breaking serve) or `kSecAttrSynchronizable: true`
/// (exfiltrating the secret) would have shipped with no failing test.
///
/// These assertions inspect the pure `MacOSKeychainStore.addAttributes` seam —
/// the same dictionary the production `write` path hands to `SecItemAdd` — so
/// they cover production WITHOUT constructing a live `SecItemAdd` or touching
/// the real login Keychain. No real-Keychain CRUD happens here (CI-safe).
@Suite("MacOSKeychainStore accessibility posture (V.13b-1)")
struct MacOSKeychainStorePostureTests {

    @Test("the SecItemAdd attribute dictionary carries AfterFirstUnlock and is never device-synced")
    func addAttributesPinsDaemonPosture() {
        let attrs = MacOSKeychainStore.addAttributes(
            service: "dev.senkani.vault.anthropic",
            account: "work",
            value: Data("sk-ant-secret".utf8)
        )

        // Accessibility: readable after first unlock, NOT only-when-unlocked.
        // (WhenUnlocked would 401 a running serve the moment the screen locks.)
        #expect(attrs[kSecAttrAccessible as String] as? String
                == (kSecAttrAccessibleAfterFirstUnlock as String))
        #expect(attrs[kSecAttrAccessible as String] as? String
                != (kSecAttrAccessibleWhenUnlocked as String))

        // Device-sync posture: the secret must NEVER be synced off the machine.
        // The invariant is that synchronizable is never `true` — absent (today)
        // or an explicit `false` both satisfy it; only `true` would exfiltrate.
        #expect(attrs[kSecAttrSynchronizable as String] as? Bool != true)

        // Lock the rest of the add dictionary so the seam can't drift: generic
        // password class, the scoped service / account, and the value payload.
        #expect(attrs[kSecClass as String] as? String == (kSecClassGenericPassword as String))
        #expect(attrs[kSecAttrService as String] as? String == "dev.senkani.vault.anthropic")
        #expect(attrs[kSecAttrAccount as String] as? String == "work")
        #expect(attrs[kSecValueData as String] as? Data == Data("sk-ant-secret".utf8))
    }
}
#endif
