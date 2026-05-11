//
//  CloudKitRecordMapping+Event.swift
//  GroupIn
//
//  Event ↔ CKRecord conversion. Kept separate from the existing
//  GroupSession/User mapping file so the per-type bridges stay
//  focused and easy to scan.
//
//  CloudKit schema (one-time manual setup in Console, just like the
//  earlier Group.inviteCode / Member.groupID indexes):
//
//    Record type:  Event
//    Fields:
//      id                  String
//      groupID             Reference (with .deleteSelf cascade)
//      authorID            String
//      createdAt           Date     ← Sortable index
//      type                String   ← Queryable index (optional, for type filters)
//      payload             Data     (JSON-encoded EventPayload)
//
//    Queryable: groupID
//    Sortable:  createdAt
//

import Foundation
import CloudKit

extension Event {
    static let recordType = "Event"

    /// Build an Event from a CKRecord. Returns nil if any required
    /// field is missing or the payload can't be decoded — same defensive
    /// shape as GroupSession's `init?(record:)`.
    init?(record: CKRecord) {
        guard
            let idString = record["id"] as? String,
            let id = UUID(uuidString: idString),
            let groupRef = record["groupID"] as? CKRecord.Reference,
            let groupID = UUID(uuidString: groupRef.recordID.recordName),
            let authorIDString = record["authorID"] as? String,
            let authorID = UUID(uuidString: authorIDString),
            let createdAt = record["createdAt"] as? Date,
            let payloadData = record["payload"] as? Data,
            let payload = try? JSONDecoder().decode(EventPayload.self, from: payloadData)
        else { return nil }

        self.init(
            id: id,
            groupID: groupID,
            authorID: authorID,
            createdAt: createdAt,
            payload: payload
        )
    }

    /// Mutates the record's fields. Caller is responsible for saving.
    /// `groupRecordID` is set with `.deleteSelf` so deleting the group
    /// cascades its event log — events have no value once their group
    /// is gone.
    func writeTo(record: CKRecord, groupRecordID: CKRecord.ID) {
        record["id"] = id.uuidString
        record["groupID"] = CKRecord.Reference(
            recordID: groupRecordID,
            action: .deleteSelf
        )
        record["authorID"] = authorID.uuidString
        record["createdAt"] = createdAt
        record["type"] = typeIdentifier
        if let payloadData = try? JSONEncoder().encode(payload) {
            record["payload"] = payloadData
        }
    }
}
