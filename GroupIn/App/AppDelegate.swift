//
//  AppDelegate.swift
//  GroupIn
//
//  Receives the silent CloudKit pushes that wake the app when a peer's
//  Member record changes. The payload itself is plumbing — we don't
//  show banners — so we just pipe each delivery into a static
//  AsyncStream. AppState consumes that stream and triggers a refresh
//  of the active group, which lets the existing newest-wins merge
//  surface the new data within ~1 second.
//
//  Required Xcode setup (one-time, manual):
//  Target → Signing & Capabilities → + Capability → Push Notifications
//  This adds the `aps-environment` entitlement that lets iOS deliver
//  CloudKit's silent pushes. The app also needs UIBackgroundModes
//  containing "remote-notification" — handled in build settings.
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    /// One stream shared across the app. AppState reads it; AppDelegate
    /// writes to it from delegate callbacks. Static so AppState doesn't
    /// have to thread the AppDelegate instance through its init.
    private static let pipe = AsyncStream<[AnyHashable: Any]>.makeStream()
    static let pushStream = pipe.stream
    private static let pushContinuation = pipe.continuation

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Skip APNs registration when CloudKit is off — there's nothing
        // to push without a server-side subscription. Saves the silent
        // failure log from `didFailToRegisterForRemoteNotifications`
        // when the aps-environment entitlement isn't present.
        if GroupInApp.useCloudKit {
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Self.pushContinuation.yield(userInfo)
        // We always claim "newData" — AppState's refresh path is the
        // authoritative check and runs regardless. Telling iOS we
        // processed work keeps our background runtime budget healthy.
        completionHandler(.newData)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Most common cause: missing aps-environment entitlement.
        // Polling fallback still works, so we silently degrade.
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // CloudKit handles its own token plumbing — we don't need to
        // forward this anywhere.
    }
}
