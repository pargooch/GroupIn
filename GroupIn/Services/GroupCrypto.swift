//
//  GroupCrypto.swift
//  GroupIn
//
//  End-to-end encryption for a group's data. Every member of a group
//  holds the same 256-bit symmetric key, minted by the creator and
//  shared only through the invite (the QR carries it). Locations, chat,
//  and avatars are sealed with this key BEFORE they touch CloudKit or
//  any realtime relay, so the backend stays zero-knowledge — it only
//  ever stores ciphertext, never a member's position.
//
//  Design notes:
//    • Primitives are CryptoKit's (`ChaChaPoly` AEAD, random 256-bit
//      keys). We compose them; we never hand-roll an algorithm.
//    • `ChaChaPoly.seal` generates a fresh random nonce per call, so
//      there is no nonce-reuse footgun even when many small payloads
//      (e.g. 1 Hz location) share one key.
//    • Keys live in the Keychain (same rationale as `LocalIdentityStore`):
//      survive uninstall, ride iCloud Keychain across the user's own
//      devices, and are readable offline.
//
//  This module is intentionally standalone and side-effect free —
//  wiring it into create/join/transport/CloudKit happens in later
//  phases so each step can be verified independently.
//

import Foundation
import CryptoKit
import Security

enum GroupCrypto {

    // MARK: - Key derivation (invite code = the secret)

    /// Derive the group's 256-bit key from its invite code via HKDF.
    /// Every member who has the code — typed or scanned — derives the
    /// exact same key, so no separate key needs to be transported. The
    /// code's entropy is therefore the security floor (Phase 3 raises the
    /// generated code length accordingly).
    static func deriveKey(fromInviteCode code: String) -> SymmetricKey {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(normalized.utf8)),
            salt: Data("GroupIn.groupkey.v1".utf8),
            info: Data("group-aead".utf8),
            outputByteCount: 32
        )
    }

    /// Derive + cache the key for a group if we don't already hold it.
    /// Idempotent and cheap to call whenever a group enters local state.
    static func ensureKey(forGroup groupID: UUID, inviteCode: String) {
        guard !hasKey(forGroup: groupID) else { return }
        store(deriveKey(fromInviteCode: inviteCode), forGroup: groupID)
    }

    /// One-way SHA-256 (hex) of the normalized invite code. Stored in
    /// CloudKit *instead of* the code itself so groups are still
    /// queryable by code, but the backend never holds the secret and
    /// therefore can't derive the key. SHA-256 is not reversible, so the
    /// hash leaks nothing usable for decryption.
    static func inviteCodeHash(_ code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Seal / open (authenticated encryption)

    /// Encrypt `plaintext` for `groupID`. Returns the combined
    /// nonce + ciphertext + tag, or nil if we don't hold the group's
    /// key (e.g. joined by manual code before the key arrived).
    static func seal(_ plaintext: Data, groupID: UUID) -> Data? {
        guard let key = key(forGroup: groupID) else { return nil }
        return try? ChaChaPoly.seal(plaintext, using: key).combined
    }

    /// Decrypt a combined box produced by `seal`. Returns nil if we
    /// lack the key or the box fails authentication (tampered / wrong
    /// key) — failing closed is the safe default.
    static func open(_ sealed: Data, groupID: UUID) -> Data? {
        guard let key = key(forGroup: groupID),
              let box = try? ChaChaPoly.SealedBox(combined: sealed) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }

    // MARK: - Keychain storage (per group)

    /// Whether we currently hold a key for this group.
    static func hasKey(forGroup groupID: UUID) -> Bool {
        key(forGroup: groupID) != nil
    }

    static func store(_ key: SymmetricKey, forGroup groupID: UUID) {
        let raw = key.withUnsafeBytes { Data($0) }
        var query = baseQuery(forGroup: groupID)
        query[kSecValueData as String] = raw
        // Replace any existing entry (key rotation overwrites in place).
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func key(forGroup groupID: UUID) -> SymmetricKey? {
        var query = baseQuery(forGroup: groupID)
        query[kSecReturnData as String] = kCFBooleanTrue!
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func removeKey(forGroup groupID: UUID) {
        SecItemDelete(baseQuery(forGroup: groupID) as CFDictionary)
    }

    // MARK: - Internals

    private static let service = "com.NDE.GroupIn.groupKey"

    private static func baseQuery(forGroup groupID: UUID) -> [String: Any] {
        [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        groupID.uuidString,
            kSecAttrAccessible as String:     kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
    }
}
