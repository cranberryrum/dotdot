//
//  Notifications.swift
//  Dot Grid
//
//  The visible half of dotdot's pushes. Delivery stays exactly as it was: the
//  silent CloudKit pushes wake the app and the fetch layer writes the App Group.
//  When permission is granted, the SAME wake also posts a local alert — one push,
//  two jobs, no second delivery path. Permission (and the per-type toggles) gate
//  the banner only, never the data flow; declining notifications leaves sending,
//  receiving, and the widget fully working.
//
//  House rules: lowercase, warm, plain copy. No emojis, no em dashes, no badges.
//  Never notify the actor of their own action. Collapse per sender (one banner
//  whose copy grows: "ravi sent you 3 dotdots"). Reaction echoes are rate-capped
//  per sender per hour. Foreground arrivals are suppressed — the in-app cues
//  (wordmark shimmer, feeds, widget) carry those.
//

import UIKit
import UserNotifications

// MARK: - Deep-link routes

/// Where a notification tap lands. Never a generic home screen: a send push opens
/// that drawing, a connected push opens that friend, a reaction echo opens the
/// reacted-to drawing in sent.
enum NotificationRoute: Equatable {
    case receivedDrawing(senderID: String, sentAt: Date)
    case friend(id: String)
    case sentDrawing(messageID: String)

    var userInfo: [String: Any] {
        switch self {
        case .receivedDrawing(let senderID, let sentAt):
            ["route": "received", "senderID": senderID,
             "sentAt": sentAt.timeIntervalSinceReferenceDate]
        case .friend(let id):
            ["route": "friend", "id": id]
        case .sentDrawing(let messageID):
            ["route": "sent", "messageID": messageID]
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        switch userInfo["route"] as? String {
        case "received":
            guard let senderID = userInfo["senderID"] as? String,
                  let interval = userInfo["sentAt"] as? TimeInterval else { return nil }
            self = .receivedDrawing(senderID: senderID,
                                    sentAt: Date(timeIntervalSinceReferenceDate: interval))
        case "friend":
            guard let id = userInfo["id"] as? String else { return nil }
            self = .friend(id: id)
        case "sent":
            guard let messageID = userInfo["messageID"] as? String else { return nil }
            self = .sentDrawing(messageID: messageID)
        default:
            return nil
        }
    }
}

// MARK: - Notifier

@MainActor
enum PushNotifier {
    private static let defaults = UserDefaults.standard
    private static let seenSendersKey = "notif.seenSenders"          // first-dotdot copy
    private static let knownFriendshipsKey = "notif.knownFriendships" // once per friendship
    private static let reactionStampsKey = "notif.reactionStamps."   // + reactorID → [Date]
    private static let reactionCapPerHour = 3

    private static let dotdotSound = UNNotificationSound(named: UNNotificationSoundName("dotdot.caf"))

    // MARK: Drawings ("a friend sent you something")

    /// Post mode-aware alerts for freshly fetched drawings, collapsed per sender.
    /// First-sender tracking is updated even when no banner is posted, so the warm
    /// first-dotdot copy can never fire late.
    static func notifyDrawings(_ drawings: [DisplayDrawing]) async {
        var seen = loadSet(seenSendersKey) {
            Set(GridStore.shared.receivedHistory().map(\.senderID))   // upgrade seed
        }
        let bySender = Dictionary(grouping: drawings.filter { !$0.senderID.isEmpty },
                                  by: \.senderID)
        let firstTimers = Set(bySender.keys.filter { !seen.contains($0) })
        seen.formUnion(bySender.keys)
        saveSet(seen, key: seenSendersKey)

        guard await canPost(AppModel.shared.notifications.drawingAlerts) else { return }

        for (senderID, group) in bySender {
            guard let latest = group.max(by: { $0.sentAt < $1.sentAt }) else { continue }
            let name = displayName(latest.senderName)
            let identifier = "drawings-\(senderID)"
            let total = await deliveredCount(identifier: identifier) + group.count

            let body: String
            if firstTimers.contains(senderID) {
                body = "your first dotdot from \(name)"
            } else if total > 1 {
                body = "\(name) sent you \(total) dotdots"
            } else {
                switch latest.kind {
                case .dots:   body = "\(name) drew you something"
                case .photo:  body = "\(name) sent you a photo"
                case .doodle: body = "\(name) doodled you something"
                }
            }
            await post(identifier: identifier, thread: "drawings-\(senderID)",
                       body: body, sound: dotdotSound, count: total,
                       route: .receivedDrawing(senderID: senderID, sentAt: latest.sentAt))
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
                       body: "\(displayName(friend.name)) connected with you",
                       sound: .default, count: 1, route: .friend(id: friend.id))
        }
    }

    // MARK: Reactions ("a friend reacted to your dotdot")

    /// Post reaction echoes, collapsed per reactor and capped per reactor per hour
    /// so a reaction spree never machine-guns the sender. `selfIDs` filters the
    /// classic subscription bug: the actor must never hear about their own action.
    static func notifyReactions(_ fetched: [SharingService.FetchedReaction], selfIDs: Set<String>) async {
        let incoming = fetched.filter { !selfIDs.contains($0.info.reactorID) }
        guard !incoming.isEmpty,
              await canPost(AppModel.shared.notifications.reactionAlerts) else { return }

        for (reactorID, group) in Dictionary(grouping: incoming, by: \.info.reactorID) {
            guard underReactionCap(reactorID) else { continue }   // data applied; banner skipped
            recordReactionPost(reactorID)
            guard let latest = group.max(by: { $0.info.at < $1.info.at }) else { continue }
            let name = displayName(latest.info.reactorName)
            let identifier = "reactions-\(reactorID)"
            let total = await deliveredCount(identifier: identifier) + group.count
            let body = total > 1
                ? "\(name) reacted to your dotdots"
                : "\(name) reacted to your dotdot"
            let route: NotificationRoute? = latest.messageID.map { .sentDrawing(messageID: $0) }
            await post(identifier: identifier, thread: "reactions-\(reactorID)",
                       body: body, sound: .default, count: total, route: route)
        }
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

    private static func underReactionCap(_ reactorID: String) -> Bool {
        recentReactionStamps(reactorID).count < reactionCapPerHour
    }

    private static func recordReactionPost(_ reactorID: String) {
        let stamps = recentReactionStamps(reactorID) + [Date()]
        defaults.set(stamps, forKey: reactionStampsKey + reactorID)
    }

    private static func recentReactionStamps(_ reactorID: String) -> [Date] {
        let stamps = (defaults.array(forKey: reactionStampsKey + reactorID) as? [Date]) ?? []
        return stamps.filter { Date().timeIntervalSince($0) < 3600 }
    }

    // MARK: Posting

    /// Replace-post: reusing the identifier per sender collapses a burst into ONE
    /// banner whose copy carries the running count ("ravi sent you 3 dotdots") —
    /// modern iOS ignores custom thread-summary text, so the copy does the job.
    private static func post(identifier: String, thread: String, body: String,
                             sound: UNNotificationSound?, count: Int,
                             route: NotificationRoute?) async {
        let content = UNMutableNotificationContent()
        content.body = body
        content.sound = sound
        content.threadIdentifier = thread
        var info = route?.userInfo ?? [:]
        info["count"] = count
        content.userInfo = info
        // Deliberately: no title (the app name reads as the title), no badge, ever.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// The running collapse count: what the delivered banner for this identifier
    /// already says, so a new arrival can say "sent you N dotdots".
    private static func deliveredCount(identifier: String) async -> Int {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        guard let existing = delivered.first(where: { $0.request.identifier == identifier }) else { return 0 }
        return existing.request.content.userInfo["count"] as? Int ?? 1
    }

    // MARK: Copy + persistence helpers

    /// Lowercase, plain — the whole app reads lowercase and so do its pushes.
    private static func displayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "a friend" : trimmed
    }

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
