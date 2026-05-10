//
//  NotificationService.swift
//  GroupIn
//
//  Local UNUserNotifications wrapper. Schedules the owner's T-30 expiry
//  reminder and surfaces taps as an AsyncStream so AppState can deep-link
//  into the right group.
//

import Foundation
import UserNotifications

enum AppNotificationType: String, Sendable {
    case expiryReminder
    case extensionProposed
    case peerNearby
}

struct NotificationTap: Sendable {
    let groupID: UUID
    let type: AppNotificationType
}

@MainActor
protocol NotificationServicing: AnyObject {
    var notificationTaps: AsyncStream<NotificationTap> { get }
    func requestAuthorization() async -> Bool
    func scheduleExpiryReminder(for group: GroupSession) async
    func cancelAll(for groupID: UUID) async
    /// Fires a tickle notification on iBeacon region entry. iOS gives us
    /// only ~10 seconds when launched in the background, so we keep the
    /// payload trivial and let the user tap into the app for details.
    /// `peerName` lets us swap the generic body for a per-peer one when
    /// region ranging identified who triggered the entry.
    func firePeerNearbyNotification(for groupID: UUID, peerName: String?) async
}

@MainActor
final class NotificationService: NSObject, NotificationServicing, UNUserNotificationCenterDelegate {
    let notificationTaps: AsyncStream<NotificationTap>
    private nonisolated let tapContinuation: AsyncStream<NotificationTap>.Continuation
    private let center = UNUserNotificationCenter.current()

    /// Per-group last-fired timestamp for the "peer nearby" notification.
    /// Drives the time-window dedup so a friend bouncing in/out of BLE
    /// range doesn't generate a notification storm.
    private var lastPeerNearbyNotifyAt: [UUID: Date] = [:]
    private static let peerNearbyDedupWindow: TimeInterval = 300  // 5 min

    override init() {
        let (stream, cont) = AsyncStream.makeStream(of: NotificationTap.self)
        self.notificationTaps = stream
        self.tapContinuation = cont
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func scheduleExpiryReminder(for group: GroupSession) async {
        let id = Self.expiryReminderID(for: group.id)
        center.removePendingNotificationRequests(withIdentifiers: [id])

        let interval = group.expiresAt.timeIntervalSince(.now) - 30 * 60
        guard interval > 1 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Group expiring soon"
        content.body = "“\(group.name)” expires in 30 minutes. Tap to extend."
        content.userInfo = [
            "groupID": group.id.uuidString,
            "type": AppNotificationType.expiryReminder.rawValue
        ]
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try? await center.add(request)
    }

    func cancelAll(for groupID: UUID) async {
        let ids = [
            Self.expiryReminderID(for: groupID),
            Self.extensionProposedID(for: groupID),
            Self.peerNearbyID(for: groupID)
        ]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func firePeerNearbyNotification(for groupID: UUID, peerName: String?) async {
        // Time-window dedup: if we've already nudged the user about this
        // group within the suppression window, skip. Prevents floods when
        // someone repeatedly enters/exits BLE range while you're walking
        // past each other in a crowd.
        let now = Date()
        if let last = lastPeerNearbyNotifyAt[groupID],
           now.timeIntervalSince(last) < Self.peerNearbyDedupWindow {
            return
        }
        lastPeerNearbyNotifyAt[groupID] = now

        let id = Self.peerNearbyID(for: groupID)
        // Coalesce repeated entries: clear any pending/delivered first so
        // we don't pile up identical notifications.
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])

        let content = UNMutableNotificationContent()
        if let peerName, !peerName.isEmpty {
            content.title = "\(peerName) is nearby"
            content.body = "Open GroupIn to find them."
        } else {
            content.title = "Someone from your group is nearby"
            content.body = "Open GroupIn to find them."
        }
        content.userInfo = [
            "groupID": groupID.uuidString,
            "type": AppNotificationType.peerNearby.rawValue
        ]
        content.sound = .default

        // Fire ASAP. UNTimeIntervalNotificationTrigger needs at least 1s.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try? await center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let groupIDString = userInfo["groupID"] as? String,
           let groupID = UUID(uuidString: groupIDString),
           let typeRaw = userInfo["type"] as? String,
           let type = AppNotificationType(rawValue: typeRaw) {
            tapContinuation.yield(NotificationTap(groupID: groupID, type: type))
        }
        completionHandler()
    }

    /// Show banner + sound even when the app is in the foreground so the
    /// owner sees the reminder regardless of where they are in the app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // MARK: - Identifiers

    private static func expiryReminderID(for groupID: UUID) -> String {
        "expiryReminder.\(groupID.uuidString)"
    }

    private static func extensionProposedID(for groupID: UUID) -> String {
        "extensionProposed.\(groupID.uuidString)"
    }

    private static func peerNearbyID(for groupID: UUID) -> String {
        "peerNearby.\(groupID.uuidString)"
    }
}
