//
//  EventDeliveryStatus.swift
//  GroupIn
//
//  Per-event delivery-tracking for *outgoing* chat messages — the
//  WhatsApp-style ⏰/✓/✓✓ indicator next to your own bubbles. Status
//  is local to the device that authored the event; it represents
//  *that author's* view of how far their message has propagated.
//
//  Four monotonic states (we only ever advance, never go backwards):
//
//    .pending  — emitted locally, no acknowledgment yet anywhere.
//                Renders ⏰.
//    .cloud    — CloudKit appendEvent succeeded. Durable; will reach
//                every member's device eventually, even those offline
//                right now. Renders ✓ (themed, light/dark).
//    .delivered — every *other* member of the group has either
//                published an eventCursor past this event OR returned
//                an explicit deliveryReceipt. Renders ✓✓ (themed).
//    .read      — every *other* member's device has rendered this
//                message on screen for ≥500ms (WhatsApp-style read),
//                confirmed by an explicit readReceipt frame. Renders
//                ✓✓ in blue.
//
//  Delivery dots render only on the author's own bubbles. Receivers
//  see no dots on the same message — that would be the author's
//  view, not theirs.
//

import Foundation

enum EventDeliveryStatus: String, Codable, Hashable, Sendable {
    case pending
    case cloud
    case delivered
    case read

    /// Integer order so the "only advance" rule is a single
    /// comparison: don't transition unless `new.rank > current.rank`.
    /// Stops out-of-order acknowledgments (a late CloudKit reply
    /// after we already saw all-peer cursors caught up) from
    /// downgrading the indicator.
    var rank: Int {
        switch self {
        case .pending:   return 0
        case .cloud:     return 1
        case .delivered: return 2
        case .read:      return 3
        }
    }
}
