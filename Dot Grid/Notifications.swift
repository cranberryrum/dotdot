//
//  Notifications.swift
//  Dot Grid
//
//  The app-side half of dotdot's alerts. Drawing and reaction banners are now
//  SERVER pushes (visible CloudKit subscriptions rewritten by the notification
//  service extension), so they arrive even when the app is force-quit. What
//  remains local: the friend-connected banner (its subscription stays silent)
//  and the your-send-failed alert. Permission and the per-type toggles gate
//  banners only, never the data flow.
//
//  House rules: lowercase, warm, plain copy. No emojis, no em dashes, no badges.
//  Never notify the actor of their own action. Foreground arrivals are
//  suppressed — the in-app cues (wordmark shimmer, feeds, widget) carry those.
//

import UIKit
import UserNotifications

@MainActor
enum PushNotifier {
    private static let defaults = UserDefaults.standard
    private static let knownFriendshipsKey = "notif.knownFriendships" // once per friendship

    // MARK: Drawings (bookkeeping only — the banner is the server push)

    /// Track senders so the extension's one-time "your first dotdot from x" copy
    /// can never fire late; runs on every fetch path regardless of banners.
    static func recordDrawingArrivals(_ drawings: [DisplayDrawing]) {
        for senderID in Set(drawings.map(\.senderID)) where !senderID.isEmpty {
            PushCopy.markSenderSeen(senderID)
        }
    }

    // MARK: Friendships ("a friend connected with you")

    /// Mark a friendship this device initiated (typed the code) — the actor never
    /// gets the connected push. Call BEFORE the roster refresh that discovers it.
    static func markFriendshipSelfInitiated(_ friendID: String) {
        var known = loadSet(knownFriendshipsKey) { Set(GridStore.shared.roster().map(\.id)) }
        known.insert(friendID)
        saveSet(known, key: knownFriendshipsKey)
    }

    /// Post "X connected with you" — once per friendship, ever. Duplicate record
    /// writes, retries, and re-discoveries are deduped by the persisted set (and
    /// the fixed identifier makes even a race collapse into one banner).
    static func notifyNewFriends(_ newFriends: [FriendInfo]) async {
        var known = loadSet(knownFriendshipsKey) { Set(GridStore.shared.roster().map(\.id)) }
        let fresh = newFriends.filter { !known.contains($0.id) }
        known.formUnion(fresh.map(\.id))
        saveSet(known, key: knownFriendshipsKey)

        guard !fresh.isEmpty, await canPost(AppModel.shared.notifications.friendAlerts) else { return }
        for friend in fresh {
            await post(identifier: "friend-\(friend.id)", thread: "friend-\(friend.id)",
                       body: "\(PushCopy.displayName(friend.name)) connected with you",
                       sound: .default, route: .friend(id: friend.id))
        }
    }

    // MARK: Send failures (your own sends, so no per-type friend toggle)

    /// A send hit a permanent/configuration error while the app was in the
    /// background — one alert, routed straight to the drawing in sent, where the
    /// resend button lives. Foreground give-ups use a toast instead (AppModel).
    static func notifySendFailed(messageID: String) async {
        guard UIApplication.shared.applicationState != .active else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        await post(identifier: "sendfailed-\(messageID)", thread: "sendfailed",
                   body: "your dotdot didn't send. tap to retry",
                   sound: .default, route: .sentDrawing(messageID: messageID))
    }

    // MARK: Gates

    /// A banner surfaces only when its toggle is on, permission is granted, and the
    /// app is NOT foregrounded (in-app cues cover foreground arrivals).
    private static func canPost(_ typeEnabled: Bool) async -> Bool {
        guard typeEnabled else { return false }
        guard UIApplication.shared.applicationState != .active else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    // MARK: Posting

    private static func post(identifier: String, thread: String, body: String,
                             sound: UNNotificationSound?, route: NotificationRoute?) async {
        let content = UNMutableNotificationContent()
        content.body = body
        content.sound = sound
        content.threadIdentifier = thread
        content.userInfo = route?.userInfo ?? [:]
        // Deliberately: no title (the app name reads as the title), no badge, ever.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: Persistence helpers

    /// Persisted string set with a lazy upgrade seed (first access on an existing
    /// install adopts current data, so nothing old is ever treated as new).
    private static func loadSet(_ key: String, seed: () -> Set<String>) -> Set<String> {
        if let stored = defaults.array(forKey: key) as? [String] { return Set(stored) }
        let seeded = seed()
        saveSet(seeded, key: key)
        return seeded
    }

    private static func saveSet(_ set: Set<String>, key: String) {
        defaults.set(Array(set), forKey: key)
    }
}
