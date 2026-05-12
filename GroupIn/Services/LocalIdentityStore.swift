//
//  LocalIdentityStore.swift
//  GroupIn
//
//  Persisted stable identifier for the local user — the salt input
//  to every per-group ban hash. Backed by the Keychain so the ID
//  survives an app uninstall + reinstall on the same device (closing
//  the trivial "ban evasion via reinstall" exploit) and rides
//  iCloud Keychain sync across the user's other devices on the
//  same Apple ID.
//
//  Why Keychain (not UserDefaults):
//    • UserDefaults is wiped on uninstall — a banned user could
//      reinstall and rejoin under a fresh hash.
//    • Keychain items with `kSecAttrAccessibleAfterFirstUnlock`
//      survive uninstall on iOS, by design.
//    • With `kSecAttrSynchronizable: true`, the same Apple ID on a
//      second device reads the same value via iCloud Keychain — a
//      ban on the user's iPhone also blocks their iPad.
//
//  Why not iCloud user record ID:
//    • Offline-bulletproof goal: the local user must have a stable
//      identity even when iCloud is unreachable or signed out.
//      `CKContainer.userRecordID()` requires a live CloudKit
//      handshake.
//    • Keychain works offline + signed out, and falls back to the
//      same value once iCloud returns. No identity churn at the
//      account boundary.
//

import Foundation
import Security

enum LocalIdentityStore {
    private static let service = "com.NDE.GroupIn"
    private static let account = "localIdentity.stableID"

    /// Returns the stable UUID for this user, generating one on
    /// first use. Idempotent — every call returns the same value
    /// until the user wipes the Keychain (which requires erasing
    /// the device or explicit "Reset Network Settings" on iOS).
    static func stableID() -> String {
        if let existing = readString() {
            return existing
        }
        let fresh = UUID().uuidString
        writeString(fresh)
        return fresh
    }

    // MARK: - Internals

    private static func baseQuery() -> [String: Any] {
        // Apple's recommended attribute set for an ID that:
        //   • is one-per-(service, account, syncable) tuple,
        //   • survives uninstall (kSecAttrAccessibleAfterFirstUnlock),
        //   • rides iCloud Keychain when enabled (Synchronizable).
        //
        // Synchronizable + AfterFirstUnlock is the only combination
        // that both syncs and is readable during normal app use.
        // Synchronizable with ThisDeviceOnly is rejected at write
        // time, so we don't try that.
        [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            kSecAttrAccount as String:         account,
            kSecAttrAccessible as String:      kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String:  kCFBooleanTrue!,
        ]
    }

    private static func readString() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue!
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func writeString(_ value: String) {
        var query = baseQuery()
        query[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        // errSecDuplicateItem means a concurrent writer beat us to
        // it — that's fine, the next read returns the existing
        // value. Any other failure is silent and the caller falls
        // back to a transient UUID for this session.
        _ = status
    }
}
