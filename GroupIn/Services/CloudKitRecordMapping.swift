//
//  CloudKitRecordMapping.swift
//  GroupIn
//
//  GroupSession ↔ CKRecord and User ↔ CKRecord conversion. Kept separate
//  from `CloudKitService` so the service file stays focused on operations.
//

import Foundation
import CloudKit

extension GroupSession {
    static let recordType = "Group"

    init?(record: CKRecord) {
        guard
            let idString = record["id"] as? String,
            let id = UUID(uuidString: idString),
            let name = record["name"] as? String,
            let inviteCode = record["inviteCode"] as? String,
            let createdAt = record["createdAt"] as? Date,
            let ownerIDString = record["ownerID"] as? String,
            let ownerID = UUID(uuidString: ownerIDString),
            let expiresAt = record["expiresAt"] as? Date
        else { return nil }

        var pending: PendingExtension?
        if
            let newExpiresAt = record["pendingNewExpiresAt"] as? Date,
            let proposedAt = record["pendingProposedAt"] as? Date
        {
            let acceptedRaw = (record["pendingAcceptedMemberIDs"] as? [String]) ?? []
            let accepted = acceptedRaw.compactMap(UUID.init(uuidString:))
            pending = PendingExtension(newExpiresAt: newExpiresAt,
                                       proposedAt: proposedAt,
                                       acceptedMemberIDs: accepted)
        }

        // Older records without `category` decode as `.other`.
        let category = (record["category"] as? String)
            .flatMap(GroupCategory.init(rawValue:)) ?? .other

        self.init(id: id,
                  name: name,
                  inviteCode: inviteCode,
                  category: category,
                  ownerID: ownerID,
                  expiresAt: expiresAt,
                  createdAt: createdAt,
                  members: [],
                  pendingExtension: pending)
    }

    /// Mutates the record's fields. Caller is responsible for `database.save`.
    func writeTo(record: CKRecord) {
        record["id"] = id.uuidString
        record["name"] = name
        record["inviteCode"] = inviteCode
        record["category"] = category.rawValue
        record["createdAt"] = createdAt
        record["ownerID"] = ownerID.uuidString
        record["expiresAt"] = expiresAt
        if let pending = pendingExtension {
            record["pendingNewExpiresAt"] = pending.newExpiresAt
            record["pendingProposedAt"] = pending.proposedAt
            record["pendingAcceptedMemberIDs"] = pending.acceptedMemberIDs.map(\.uuidString)
        } else {
            record["pendingNewExpiresAt"] = nil
            record["pendingProposedAt"] = nil
            record["pendingAcceptedMemberIDs"] = nil
        }
    }
}

extension User {
    static let recordType = "Member"

    init?(record: CKRecord, groupID: UUID) {
        guard
            let idString = record["id"] as? String,
            let id = UUID(uuidString: idString),
            let displayName = record["displayName"] as? String,
            let lastSeen = record["lastSeen"] as? Date
        else { return nil }

        var coordinate: Coordinate?
        if let lat = record["latitude"] as? Double,
           let lon = record["longitude"] as? Double {
            coordinate = Coordinate(latitude: lat, longitude: lon)
        }

        let avatarData = record["avatarData"] as? Data
        let heading = record["heading"] as? Double
        let nearbyToken = record["nearbyToken"] as? Data

        self.init(id: id,
                  displayName: displayName,
                  avatarData: avatarData,
                  lastSeen: lastSeen,
                  coordinate: coordinate,
                  heading: heading,
                  nearbyToken: nearbyToken)
    }

    /// Mutates the record's fields. Caller is responsible for `database.save`.
    /// `groupRecordID` is wired with `.deleteSelf` so deleting the group record
    /// cascades the member rows.
    func writeTo(record: CKRecord, groupRecordID: CKRecord.ID) {
        record["id"] = id.uuidString
        record["groupID"] = CKRecord.Reference(recordID: groupRecordID, action: .deleteSelf)
        record["displayName"] = displayName
        record["lastSeen"] = lastSeen
        record["avatarData"] = avatarData
        if let coordinate {
            record["latitude"] = coordinate.latitude
            record["longitude"] = coordinate.longitude
        } else {
            record["latitude"] = nil
            record["longitude"] = nil
        }
        record["heading"] = heading
        record["nearbyToken"] = nearbyToken
    }
}
