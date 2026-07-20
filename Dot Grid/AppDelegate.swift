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
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            completionHandler(.noData)
            return
        }
        Task {
            // The subscription id tells handlePush what the push is for, so a
            // drawing push doesn't burn its background budget refreshing friends.
            let queryNote = note as? CKQueryNotification
            let fetched = await AppModel.shared.handlePush(
                subscriptionID: note.subscriptionID,
                recordID: queryNote?.recordID)
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
        let userInfo = response.notification.request.content.userInfo
        let cloudNote = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification
        let subscriptionID = cloudNote?.subscriptionID
            ?? userInfo[NotificationDeliveryKey.subscriptionID] as? String
        let recordID = cloudNote?.recordID
            ?? (userInfo[NotificationDeliveryKey.recordName] as? String).map(CKRecord.ID.init(recordName:))

        // Finish exact ingestion before the inbox sheet snapshots GridStore.
        if subscriptionID != nil || recordID != nil {
            _ = await AppModel.shared.handlePush(
                subscriptionID: subscriptionID,
                recordID: recordID)
        }

        var route = NotificationRoute(userInfo: userInfo)
        if route == nil, let fields = cloudNote?.recordFields {
            if subscriptionID?.hasPrefix("drawings-to-") == true,
               let senderID = fields["senderID"] as? String,
               let sentAt = fields["sentAt"] as? Date {
                route = .receivedDrawing(senderID: senderID, sentAt: sentAt)
            } else if subscriptionID?.hasPrefix("reactions-to-") == true,
                      let messageID = fields["messageID"] as? String {
                route = .sentDrawing(messageID: messageID)
            }
        }
        // If CloudKit pruned desiredKeys, derive the route from the exact row that
        // handlePush just committed.
        if route == nil, subscriptionID?.hasPrefix("drawings-to-") == true,
           let recordName = recordID?.recordName,
           let drawing = GridStore.shared.receivedHistory().first(where: { $0.recordName == recordName }) {
            route = .receivedDrawing(senderID: drawing.senderID, sentAt: drawing.sentAt)
        }
        guard let route else { return }
        await MainActor.run { AppModel.shared.pendingRoute = route }
    }
}
