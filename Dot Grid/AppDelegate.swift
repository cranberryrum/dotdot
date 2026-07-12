//
//  AppDelegate.swift
//  Dot Grid
//
//  Registers for remote notifications so CloudKit can push when a friend sends a
//  drawing. On a push we fetch the new drawing into the App Group and reload the
//  widget. The app also fetches on launch/foreground, so push is best-effort only.
//

import CloudKit
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Silent CloudKit pushes need no user permission, just registration.
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Only act on CloudKit notifications.
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }
        Task {
            let fetched = await AppModel.shared.handlePush()
            // Report honestly — iOS tracks this to decide how eagerly to keep
            // waking us for future silent pushes.
            completionHandler(fetched ? .newData : .noData)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Non-fatal: the app still fetches on launch/foreground.
    }
}
