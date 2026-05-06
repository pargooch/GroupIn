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
}

@MainActor
final class NotificationService: NSObject, NotificationServicing, UNUserNotificationCenterDelegate {
    let notificationTaps: AsyncStream<NotificationTap>
    private nonisolated let tapContinuation: AsyncStream<NotificationTap>.Continuation
    private let center = UNUserNotificationCenter.current()

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
            Self.extensionProposedID(for: groupID)
        ]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
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
}
