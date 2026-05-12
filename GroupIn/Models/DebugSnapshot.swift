//
//  DebugSnapshot.swift
//  GroupIn
//
//  One-shot diagnostic dump rendered by the dev-only debug overlay.
//  Captures the state that's hardest to reason about from the
//  outside — retry queues, peer cursors, BLE health, last events —
//  so "everything's broken" becomes a 10-second diagnosis instead
//  of a multi-hour bisect.
//
//  `#if DEBUG`-gated at the AppState surface so production binaries
//  don't carry the data-gathering code paths.
//

import Foundation

#if DEBUG
struct DebugSnapshot {
    let localIdentity: String?
    let isOnline: Bool
    let iCloudStatus: ICloudAccountStatus
    let pendingEmitsCount: Int
    let pendingMemberPublishesCount: Int
    let pendingGroupSavesCount: Int
    /// Wall-clock createdAt of the oldest queued emit, if any. Used
    /// to surface "stuck for 12 minutes" diagnostics — if this drifts
    /// far into the past while online, something's wrong with the
    /// drain path.
    let oldestPendingEmitAt: Date?
    let bleDiagnostics: BLEDiagnostics
    let activeGroupID: UUID?
    let activeGroupName: String?
    let activeGroupMemberCount: Int
    let activeGroupEventCount: Int
    let myCursor: EventCursor?
    let peerCursors: [PeerCursorEntry]
    let recentEvents: [Event]

    struct PeerCursorEntry: Identifiable {
        let memberID: UUID
        let displayName: String?
        let cursor: EventCursor
        let myCursor: EventCursor?
        /// How many events we have locally that this peer hasn't
        /// acknowledged yet. Nil if we don't have the active group
        /// in scope. Zero = caught up; positive = behind.
        let behindByEvents: Int?

        var id: UUID { memberID }
    }
}
#endif
