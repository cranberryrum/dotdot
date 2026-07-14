//
//  AppDelegate.swift
//  Dot Grid
//
//  Registers for remote notifications so CloudKit can push when a friend sends a
//  drawing. On a push we fetch the new drawing into the App Group and reload the
//  widget. The app also fetches on launch/foreground, so push is best-effort only.
//

import BackgroundTasks
import CloudKit
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Silent CloudKit pushes need no user permission, just registration.
        application.registerForRemoteNotifications()
        UNUserNotificationCenter.current().delegate = self
        registerBackgroundFlush()
        return true
    }

    /// Background outbox drain: iOS grants a short window at a time of its
    /// choosing; the handler flushes and re-asks while anything remains. The
    /// foreground paths stay the guarantee — this just means a queued send no
    /// longer needs the app OPEN to leave the phone.
    private func registerBackgroundFlush() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppModel.flushTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let work = Task { @MainActor in
                await AppModel.shared.flushOutbox()
                if !AppModel.shared.outbox.isEmpty { AppModel.scheduleBackgroundFlush() }
                refresh.setTaskCompleted(success: true)
            }
            refresh.expirationHandler = {
                work.cancel()
                refresh.setTaskCompleted(success: false)
            }
        }
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

// MARK: - Visible notification behavior

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Foreground suppression: while the app is open, the in-app cues (wordmark
    /// shimmer, feeds, widget) carry arrivals — no banner over the composer.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    /// A tap lands somewhere specific: the drawing, the friend, or the reacted-to
    /// dotdot in sent — never a generic home screen.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = NotificationRoute(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { AppModel.shared.pendingRoute = route }
    }
}
