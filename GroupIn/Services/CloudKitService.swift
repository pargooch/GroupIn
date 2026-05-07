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
    case schemaIncomplete
    case other(Error)

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            return "Couldn't read group data from CloudKit."
        case .notSignedIn:
            return "Sign in to iCloud in Settings to use GroupIn."
        case .schemaIncomplete:
            return "CloudKit schema not ready. Mark inviteCode/groupID as queryable in CloudKit Console."
        case .other(let err):
            return err.localizedDescription
        }
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

        var record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let ckError as CKError where ckError.code == .unknownItem {
            record = CKRecord(recordType: User.recordType, recordID: recordID)
        } catch let ckError as CKError {
            throw mapCKError(ckError)
        }

        user.writeTo(record: record, groupRecordID: groupRecordID)
        try await save(record)
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
        let groupRef = CKRecord.Reference(recordID: groupRecordID, action: .deleteSelf)
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
            // CloudKit returns this when the field isn't marked queryable.
            if error.localizedDescription.lowercased().contains("queryable") {
                return CloudKitError.schemaIncomplete
            }
            return CloudKitError.other(error)
        default:
            return CloudKitError.other(error)
        }
    }

    // MARK: - Invite codes

    private static func generateInviteCode(length: Int = 6) -> String {
        let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}
