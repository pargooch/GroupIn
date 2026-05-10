//
//  CloudKitService.swift
//  GroupIn
//
//  CloudKit-backed implementation of `CloudKitServicing`. Uses the public
//  database so any iCloud-signed-in user can join a group with an invite
//  code without explicit sharing flows.
//
//  Required Xcode setup (one-time, manual):
//    Target → Signing & Capabilities → + Capability → iCloud → check CloudKit
//    Add a container (default: iCloud.<bundleID>)
//
//  Required CloudKit Console setup (one-time, manual):
//    After the first record is written by running the app once, open the
//    container in CloudKit Console and mark the following fields as
//    queryable so `joinGroup` and `fetchMembers` can find them:
//      - Group.inviteCode  (queryable + sortable)
//      - Member.groupID    (queryable)
//

import Foundation
import CloudKit

enum CloudKitError: LocalizedError {
    case invalidRecord
    case notSignedIn
    case schemaIncomplete(field: String?)
    case other(Error)

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            return "Couldn't read group data from CloudKit."
        case .notSignedIn:
            return "Sign in to iCloud in Settings to use GroupIn."
        case .schemaIncomplete(let field):
            if let field {
                return "CloudKit field '\(field)' isn't queryable. Open CloudKit Console → Schema → Indexes and add a Queryable index for it, then deploy."
            }
            return "CloudKit schema isn't ready. Mark Group.inviteCode and Member.groupID as queryable in CloudKit Console, then deploy."
        case .other(let err):
            // Surface the raw error verbatim so we don't lose context.
            // CKError descriptions usually contain the field name and
            // the underlying server-side complaint, which is exactly
            // what we need to debug schema issues without attaching a
            // debugger.
            if let ckError = err as? CKError {
                return "CloudKit error \(ckError.code.rawValue) (\(ckErrorCodeName(ckError.code))): \(ckError.localizedDescription)"
            }
            return err.localizedDescription
        }
    }
}

/// Human-readable name for a CKError.Code value. The default
/// `localizedDescription` often hides the code name — this lets the
/// error surface "ZONE_NOT_FOUND" or "PARTIAL_FAILURE" instead of a
/// generic "An error occurred."
private func ckErrorCodeName(_ code: CKError.Code) -> String {
    switch code {
    case .internalError:           return "internalError"
    case .partialFailure:          return "partialFailure"
    case .networkUnavailable:      return "networkUnavailable"
    case .networkFailure:          return "networkFailure"
    case .badContainer:            return "badContainer"
    case .serviceUnavailable:      return "serviceUnavailable"
    case .requestRateLimited:      return "requestRateLimited"
    case .missingEntitlement:      return "missingEntitlement"
    case .notAuthenticated:        return "notAuthenticated"
    case .permissionFailure:       return "permissionFailure"
    case .unknownItem:             return "unknownItem"
    case .invalidArguments:        return "invalidArguments"
    case .resultsTruncated:        return "resultsTruncated"
    case .serverRecordChanged:     return "serverRecordChanged"
    case .serverRejectedRequest:   return "serverRejectedRequest"
    case .assetFileNotFound:       return "assetFileNotFound"
    case .assetFileModified:       return "assetFileModified"
    case .incompatibleVersion:     return "incompatibleVersion"
    case .constraintViolation:     return "constraintViolation"
    case .operationCancelled:      return "operationCancelled"
    case .changeTokenExpired:      return "changeTokenExpired"
    case .batchRequestFailed:      return "batchRequestFailed"
    case .zoneBusy:                return "zoneBusy"
    case .badDatabase:             return "badDatabase"
    case .quotaExceeded:           return "quotaExceeded"
    case .zoneNotFound:            return "zoneNotFound"
    case .limitExceeded:           return "limitExceeded"
    case .userDeletedZone:         return "userDeletedZone"
    case .tooManyParticipants:     return "tooManyParticipants"
    case .alreadyShared:           return "alreadyShared"
    case .referenceViolation:      return "referenceViolation"
    case .managedAccountRestricted: return "managedAccountRestricted"
    case .participantMayNeedVerification: return "participantMayNeedVerification"
    case .serverResponseLost:      return "serverResponseLost"
    case .assetNotAvailable:       return "assetNotAvailable"
    case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
    @unknown default:              return "unknown(\(code.rawValue))"
    }
}

@MainActor
final class CloudKitService: CloudKitServicing {
    private let container: CKContainer
    private let database: CKDatabase

    init(container: CKContainer = .default()) {
        self.container = container
        self.database = container.publicCloudDatabase
    }

    // MARK: - Create / Join

    func createGroup(named name: String,
                     category: GroupCategory,
                     ownerID: UUID,
                     expiresAt: Date) async throws -> GroupSession {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GroupServiceError.invalidName }

        let group = GroupSession(
            name: trimmed,
            inviteCode: Self.generateInviteCode(),
            category: category,
            ownerID: ownerID,
            expiresAt: expiresAt
        )

        let recordID = CKRecord.ID(recordName: group.id.uuidString)
        let record = CKRecord(recordType: GroupSession.recordType, recordID: recordID)
        group.writeTo(record: record)

        try await save(record)
        return group
    }

    func joinGroup(inviteCode: String) async throws -> GroupSession {
        let normalized = inviteCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty else { throw GroupServiceError.invalidCode }

        let predicate = NSPredicate(format: "inviteCode == %@", normalized)
        let query = CKQuery(recordType: GroupSession.recordType, predicate: predicate)

        let matchResults: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            let result = try await database.records(matching: query, resultsLimit: 1)
            matchResults = result.matchResults
        } catch let error as CKError {
            throw mapCKError(error)
        }

        guard let firstResult = matchResults.first?.1 else {
            throw GroupServiceError.groupNotFound
        }

        switch firstResult {
        case .success(let record):
            guard var group = GroupSession(record: record) else {
                throw CloudKitError.invalidRecord
            }
            group.members = try await fetchMembers(groupRecordID: record.recordID, groupID: group.id)
            return group
        case .failure(let error):
            if let ckError = error as? CKError { throw mapCKError(ckError) }
            throw error
        }
    }

    func fetchGroup(groupID: UUID) async throws -> GroupSession? {
        let recordID = CKRecord.ID(recordName: groupID.uuidString)
        do {
            let record = try await database.record(for: recordID)
            return try await groupSession(from: record)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            return nil
        } catch let ckError as CKError {
            throw mapCKError(ckError)
        }
    }

    func publish(user: User, in group: GroupSession) async throws {
        let recordID = CKRecord.ID(recordName: user.id.uuidString)
        let groupRecordID = CKRecord.ID(recordName: group.id.uuidString)

        let record = CKRecord(recordType: User.recordType, recordID: recordID)
        user.writeTo(record: record, groupRecordID: groupRecordID)

        // `.allKeys` writes regardless of the server-side etag —
        // CloudKit creates the record if it doesn't exist and
        // overwrites all fields if it does. Unlike the default
        // `.ifServerRecordUnchanged` policy, it doesn't require
        // fetching the existing record first to get a valid etag,
        // which means **one network roundtrip in all cases**:
        //   • first publish from create / join → no wasted fetch
        //   • update from heartbeat / location → no wasted fetch
        // This is the right policy for our model where the device
        // publishing the record is also the canonical owner of its
        // contents — there's no concurrent writer to merge with.
        do {
            let result = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .allKeys,
                atomically: true
            )
            if case .failure(let err) = result.saveResults[recordID] ?? .success(record) {
                if let ckError = err as? CKError {
                    throw mapCKError(ckError)
                }
                throw err
            }
        } catch let ckError as CKError {
            throw mapCKError(ckError)
        }
    }

    // MARK: - Extension flow

    func proposeExtension(groupID: UUID,
                         newExpiresAt: Date) async throws -> GroupSession {
        let recordID = CKRecord.ID(recordName: groupID.uuidString)
        let record = try await fetchRecord(id: recordID)

        record["pendingNewExpiresAt"] = newExpiresAt
        record["pendingProposedAt"] = Date()
        record["pendingAcceptedMemberIDs"] = [String]()

        try await save(record)

        return try await groupSession(from: record)
    }

    func acceptExtension(groupID: UUID,
                        memberID: UUID) async throws -> GroupSession {
        let recordID = CKRecord.ID(recordName: groupID.uuidString)
        let record = try await fetchRecord(id: recordID)

        var accepted = (record["pendingAcceptedMemberIDs"] as? [String]) ?? []
        if !accepted.contains(memberID.uuidString) {
            accepted.append(memberID.uuidString)
            record["pendingAcceptedMemberIDs"] = accepted
        }
        try await save(record)
        return try await groupSession(from: record)
    }

    func resolveExpiry(groupID: UUID) async throws -> GroupSession? {
        let recordID = CKRecord.ID(recordName: groupID.uuidString)

        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            return nil // Already deleted server-side.
        } catch let ckError as CKError {
            throw mapCKError(ckError)
        }

        guard let group = GroupSession(record: record) else {
            throw CloudKitError.invalidRecord
        }

        if let pending = group.pendingExtension {
            let allMembers = try await fetchMembers(groupRecordID: record.recordID,
                                                    groupID: group.id)
            let acceptedIDs = Set(pending.acceptedMemberIDs)
            let toKeep = allMembers.filter {
                $0.id == group.ownerID || acceptedIDs.contains($0.id)
            }
            let toDelete = allMembers.filter {
                $0.id != group.ownerID && !acceptedIDs.contains($0.id)
            }

            record["expiresAt"] = pending.newExpiresAt
            record["pendingNewExpiresAt"] = nil
            record["pendingProposedAt"] = nil
            record["pendingAcceptedMemberIDs"] = nil

            let deleteIDs = toDelete.map { CKRecord.ID(recordName: $0.id.uuidString) }
            do {
                _ = try await database.modifyRecords(saving: [record], deleting: deleteIDs)
            } catch let ckError as CKError {
                throw mapCKError(ckError)
            }

            guard var updated = GroupSession(record: record) else {
                throw CloudKitError.invalidRecord
            }
            updated.members = toKeep
            return updated
        } else {
            // Hard delete: group + all members in one network round trip.
            let memberIDs = try await fetchMembers(groupRecordID: record.recordID,
                                                   groupID: group.id)
                .map { CKRecord.ID(recordName: $0.id.uuidString) }
            let allIDs = memberIDs + [recordID]
            do {
                _ = try await database.modifyRecords(saving: [], deleting: allIDs)
            } catch let ckError as CKError {
                throw mapCKError(ckError)
            }
            return nil
        }
    }

    // MARK: - Subscriptions

    func subscribeToPresenceUpdates(groupID: UUID) async throws {
        let groupRecordID = CKRecord.ID(recordName: groupID.uuidString)
        let groupRef = CKRecord.Reference(recordID: groupRecordID, action: .none)
        let predicate = NSPredicate(format: "groupID == %@", groupRef)

        let subscriptionID = Self.subscriptionID(for: groupID)
        let subscription = CKQuerySubscription(
            recordType: User.recordType,
            predicate: predicate,
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )

        // Silent push: shouldSendContentAvailable wakes the app in the
        // background without showing a banner. The body / title fields
        // are intentionally left nil — this notification is plumbing,
        // not a user-facing message.
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info

        do {
            _ = try await database.save(subscription)
        } catch let ckError as CKError where ckError.code == .serverRejectedRequest {
            // Most common cause: a subscription with this ID already
            // exists from a previous session. CloudKit persists
            // subscriptions across app launches, so this is fine — our
            // re-registration is just confirming what's already there.
        } catch let ckError as CKError {
            throw mapCKError(ckError)
        }
    }

    func unsubscribeFromPresenceUpdates(groupID: UUID) async throws {
        let subscriptionID = Self.subscriptionID(for: groupID)
        do {
            _ = try await database.deleteSubscription(withID: subscriptionID)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            // Already gone — nothing to clean up.
        } catch let ckError as CKError {
            throw mapCKError(ckError)
        }
    }

    private static func subscriptionID(for groupID: UUID) -> String {
        "presence-\(groupID.uuidString)"
    }

    // MARK: - Owner delete

    func deleteGroup(groupID: UUID) async throws {
        let recordID = CKRecord.ID(recordName: groupID.uuidString)

        // Best-effort: also clear the subscription so we don't leak it
        // server-side. Failures here shouldn't block the group delete.
        let subID = Self.subscriptionID(for: groupID)
        _ = try? await database.deleteSubscription(withID: subID)

        // Reuse the resolveExpiry hard-delete path: fetch members, batch-
        // delete them along with the group record. CKRecord.Reference
        // action `.deleteSelf` would cascade if we modified records via
        // the batch op anyway, but doing it explicitly keeps it sturdy
        // even if the parent reference field is missing for some reason.
        let memberIDs: [CKRecord.ID]
        do {
            let members = try await fetchMembers(groupRecordID: recordID,
                                                 groupID: groupID)
            memberIDs = members.map { CKRecord.ID(recordName: $0.id.uuidString) }
        } catch {
            memberIDs = []
        }

        do {
            _ = try await database.modifyRecords(
                saving: [],
                deleting: memberIDs + [recordID]
            )
        } catch let ckError as CKError where ckError.code == .unknownItem {
            // Already gone server-side. Treat as success.
        } catch let ckError as CKError {
            throw mapCKError(ckError)
        }
    }

    // MARK: - Owner-initiated member removal

    func removeMember(memberID: UUID,
                      fromGroup groupID: UUID) async throws -> GroupSession {
        let memberRecordID = CKRecord.ID(recordName: memberID.uuidString)
        let groupRecordID = CKRecord.ID(recordName: groupID.uuidString)

        // Read the kicked member's banHash + display name BEFORE
        // deleting their record. Without this snapshot the banlist
        // entry would have nothing to record. If the member record
        // is already gone (race with another admin device), we fall
        // through to deletion with no banlist update.
        var capturedBan: BannedMember?
        if let memberRecord = try? await database.record(for: memberRecordID),
           let user = User(record: memberRecord, groupID: groupID),
           let hash = user.banHash {
            capturedBan = BannedMember(
                banHash: hash,
                displayName: user.displayName,
                bannedAt: .now
            )
        }

        do {
            _ = try await database.deleteRecord(withID: memberRecordID)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            // Already gone — proceed to write the banlist update anyway.
        } catch let ckError as CKError {
            throw mapCKError(ckError)
        }

        // Append to the group's banlist if we managed to snapshot the
        // member's hash. Doing this in a separate write keeps the
        // delete and the banlist mutation independent — if the banlist
        // write fails, the member is still removed.
        if let entry = capturedBan {
            try await appendBanlistEntry(entry, on: groupRecordID)
        }

        let groupRecord = try await fetchRecord(id: groupRecordID)
        return try await groupSession(from: groupRecord)
    }

    func unbanMember(banHash: String,
                     fromGroup groupID: UUID) async throws -> GroupSession {
        let groupRecordID = CKRecord.ID(recordName: groupID.uuidString)
        let record = try await fetchRecord(id: groupRecordID)

        var hashes = (record["bannedHashes"] as? [String]) ?? []
        var names = (record["bannedNames"] as? [String]) ?? []
        var dates = (record["bannedTimestamps"] as? [Date]) ?? []

        // Find and excise the entry. Lengths are kept in lockstep so
        // a future ban append doesn't desync the parallel arrays.
        let count = min(hashes.count, names.count, dates.count)
        var keepHashes: [String] = []
        var keepNames: [String] = []
        var keepDates: [Date] = []
        for i in 0..<count where hashes[i] != banHash {
            keepHashes.append(hashes[i])
            keepNames.append(names[i])
            keepDates.append(dates[i])
        }
        hashes = keepHashes
        names = keepNames
        dates = keepDates

        if hashes.isEmpty {
            record["bannedHashes"] = nil
            record["bannedNames"] = nil
            record["bannedTimestamps"] = nil
        } else {
            record["bannedHashes"] = hashes
            record["bannedNames"] = names
            record["bannedTimestamps"] = dates
        }
        try await save(record)
        return try await groupSession(from: record)
    }

    /// Read-modify-write append on the group record's banlist arrays.
    /// Pulled into its own helper so removeMember stays focused on the
    /// kick flow and the parallel-array invariant lives in one place.
    private func appendBanlistEntry(_ entry: BannedMember,
                                    on groupRecordID: CKRecord.ID) async throws {
        let record = try await fetchRecord(id: groupRecordID)

        var hashes = (record["bannedHashes"] as? [String]) ?? []
        var names = (record["bannedNames"] as? [String]) ?? []
        var dates = (record["bannedTimestamps"] as? [Date]) ?? []

        // Idempotent on hash — re-banning the same person doesn't
        // duplicate them in the list.
        guard !hashes.contains(entry.banHash) else { return }
        hashes.append(entry.banHash)
        names.append(entry.displayName)
        dates.append(entry.bannedAt)

        record["bannedHashes"] = hashes
        record["bannedNames"] = names
        record["bannedTimestamps"] = dates
        try await save(record)
    }

    func cloudUserID() async -> String? {
        do {
            let id = try await container.userRecordID()
            return id.recordName
        } catch {
            return nil
        }
    }

    // MARK: - Account preflight

    func iCloudAccountStatus() async -> ICloudAccountStatus {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:               return .available
            case .noAccount:               return .noAccount
            case .restricted:              return .restricted
            case .couldNotDetermine:       return .couldNotDetermine
            case .temporarilyUnavailable:  return .temporarilyUnavailable
            @unknown default:              return .couldNotDetermine
            }
        } catch {
            return .couldNotDetermine
        }
    }

    // MARK: - Internals

    private func fetchRecord(id: CKRecord.ID) async throws -> CKRecord {
        do {
            return try await database.record(for: id)
        } catch let ckError as CKError {
            throw mapCKError(ckError)
        }
    }

    private func save(_ record: CKRecord) async throws {
        do {
            _ = try await database.save(record)
        } catch let ckError as CKError {
            throw mapCKError(ckError)
        }
    }

    private func fetchMembers(groupRecordID: CKRecord.ID,
                              groupID: UUID) async throws -> [User] {
        // Predicate references use `.none` action — we're matching by
        // recordID equality, not asking for a cascade behavior. Some
        // predicate paths in CloudKit are picky about action values
        // not matching the original write, so keeping reads neutral
        // avoids subtle "no results" failures.
        let groupRef = CKRecord.Reference(recordID: groupRecordID, action: .none)
        let predicate = NSPredicate(format: "groupID == %@", groupRef)
        let query = CKQuery(recordType: User.recordType, predicate: predicate)

        do {
            let result = try await database.records(matching: query)
            return result.matchResults.compactMap { _, recordResult in
                guard case .success(let record) = recordResult else { return nil }
                return User(record: record, groupID: groupID)
            }
        } catch let ckError as CKError {
            throw mapCKError(ckError)
        }
    }

    private func groupSession(from record: CKRecord) async throws -> GroupSession {
        guard var group = GroupSession(record: record) else {
            throw CloudKitError.invalidRecord
        }
        group.members = try await fetchMembers(groupRecordID: record.recordID,
                                               groupID: group.id)
        return group
    }

    private func mapCKError(_ error: CKError) -> Error {
        switch error.code {
        case .notAuthenticated:
            return CloudKitError.notSignedIn
        case .unknownItem:
            return GroupServiceError.groupNotFound
        case .invalidArguments:
            // CloudKit returns invalidArguments for both "field not
            // queryable" and "field type mismatch." Pull the field name
            // out of the description so the user sees actionable copy
            // rather than the generic 12.
            let desc = error.localizedDescription
            if desc.lowercased().contains("queryable")
                || desc.lowercased().contains("not marked") {
                return CloudKitError.schemaIncomplete(field: extractFieldName(from: desc))
            }
            return CloudKitError.other(error)
        default:
            return CloudKitError.other(error)
        }
    }

    /// Best-effort scrape for a backtick-quoted or single-quoted field
    /// name in a CloudKit error description. Returns nil if no field
    /// can be identified — the caller falls back to a generic message.
    private func extractFieldName(from description: String) -> String? {
        // CloudKit phrases vary: "Field 'groupID' is not queryable",
        // "field `inviteCode` is not marked indexable", etc.
        for delimiter in ["'", "`", "\""] {
            let parts = description.components(separatedBy: delimiter)
            // Pattern: prefix, fieldName, suffix → at least 3 parts.
            if parts.count >= 3, !parts[1].isEmpty, parts[1].count < 50 {
                return parts[1]
            }
        }
        return nil
    }

    // MARK: - Invite codes

    private static func generateInviteCode(length: Int = 6) -> String {
        let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}
