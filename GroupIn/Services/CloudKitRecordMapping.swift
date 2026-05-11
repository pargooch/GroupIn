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

        // Banlist is stored as three parallel arrays so the schema
        // stays in CloudKit primitives. Decoder is defensive: missing
        // arrays = empty banlist; mismatched lengths fall back to the
        // shortest array so we never read past an index.
        let banHashes = (record["bannedHashes"] as? [String]) ?? []
        let banNames = (record["bannedNames"] as? [String]) ?? []
        let banDates = (record["bannedTimestamps"] as? [Date]) ?? []
        let banCount = min(banHashes.count, banNames.count, banDates.count)
        let bannedMembers: [BannedMember] = (0..<banCount).map { i in
            BannedMember(
                banHash: banHashes[i],
                displayName: banNames[i],
                bannedAt: banDates[i]
            )
        }

        self.init(id: id,
                  name: name,
                  inviteCode: inviteCode,
                  category: category,
                  ownerID: ownerID,
                  expiresAt: expiresAt,
                  createdAt: createdAt,
                  members: [],
                  pendingExtension: pending,
                  bannedMembers: bannedMembers)
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
        // Banlist round-trip: same parallel-arrays shape the decoder
        // expects. Empty banlist clears all three fields to nil so the
        // record doesn't accumulate stale data.
        if bannedMembers.isEmpty {
            record["bannedHashes"] = nil
            record["bannedNames"] = nil
            record["bannedTimestamps"] = nil
        } else {
            record["bannedHashes"] = bannedMembers.map(\.banHash)
            record["bannedNames"] = bannedMembers.map(\.displayName)
            record["bannedTimestamps"] = bannedMembers.map(\.bannedAt)
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
        let banHash = record["banHash"] as? String

        // Provenance fields — all optional, decode defensively. Old
        // records (pre-Path-B) have only lat/lon, no source. The
        // User model's `positionEstimate` accessor falls back to
        // `.gps` with a high default accuracy in that case.
        let accuracy = record["positionAccuracy"] as? Double
        let positionSource = (record["positionSource"] as? String)
            .flatMap(PositionSource.init(rawValue:))
        let positionAnchorAt = record["positionAnchorAt"] as? Date
        let positionSourcePeerID = (record["positionSourcePeerID"] as? String)
            .flatMap(UUID.init(uuidString:))

        // Event cursor (Path C.4.2) — what this member has
        // acknowledged locally. Drives delivery-dot rendering for
        // other members. Both fields optional and decoded defensively;
        // either missing → no usable cursor → treated as "unknown."
        let cursorDate = record["eventCursorCreatedAt"] as? Date
        let cursorID = (record["eventCursorID"] as? String)
            .flatMap(UUID.init(uuidString:))
        let eventCursor = (cursorDate != nil && cursorID != nil)
            ? EventCursor(createdAt: cursorDate!, id: cursorID!)
            : nil

        self.init(id: id,
                  displayName: displayName,
                  avatarData: avatarData,
                  lastSeen: lastSeen,
                  coordinate: coordinate,
                  heading: heading,
                  nearbyToken: nearbyToken,
                  banHash: banHash,
                  accuracy: accuracy,
                  positionSource: positionSource,
                  positionAnchorAt: positionAnchorAt,
                  positionSourcePeerID: positionSourcePeerID,
                  eventCursor: eventCursor)
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
        record["banHash"] = banHash

        // Provenance — write only when populated so legacy records
        // don't accumulate nil fields, keeping CloudKit storage tidy
        // and the schema additions opt-in until the first write from
        // a Path-B-aware client.
        record["positionAccuracy"] = accuracy
        record["positionSource"] = positionSource?.rawValue
        record["positionAnchorAt"] = positionAnchorAt
        record["positionSourcePeerID"] = positionSourcePeerID?.uuidString

        // Event cursor — published on every heartbeat so other
        // members can resolve delivery status for their outgoing
        // events. Same opt-in semantics as the provenance fields.
        record["eventCursorCreatedAt"] = eventCursorCreatedAt
        record["eventCursorID"] = eventCursorID?.uuidString
    }
}
