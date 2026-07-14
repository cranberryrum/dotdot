//
//  NotificationRoute.swift
//  Dot Grid
//
//  Deep-link targets a notification tap can land on, plus the house-style push
//  copy. Shared between the app (tap handling, local posts) and the notification
//  service extension (banner rewriting) so both speak the same language.
//

import Foundation

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

/// House-style push copy: lowercase, warm, plain. No emojis, no em dashes.
/// One voice whether the banner comes from the service extension or a local post.
enum PushCopy {
    /// Lowercase, trimmed — the whole app reads lowercase and so do its pushes.
    static func displayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "a friend" : trimmed
    }

    static func drawingBody(kind: MessageKind, senderName: String, firstFromSender: Bool) -> String {
        let name = displayName(senderName)
        if firstFromSender { return "your first dotdot from \(name)" }
        switch kind {
        case .dots:   return "\(name) drew you something"
        case .photo:  return "\(name) sent you a photo"
        case .doodle: return "\(name) doodled you something"
        }
    }

    static func reactionBody(reactorName: String) -> String {
        "\(PushCopy.displayName(reactorName)) reacted to your dotdot"
    }

    /// The senders this device has ever received from — powers the one-time warm
    /// first-dotdot copy. Lives in the App Group so the app and the notification
    /// service extension share one memory. Lazily seeded from the received history
    /// on upgrade so old friends never read as new.
    static let seenSendersKey = "notif.seenSenders"

    static func isFirstFromSender(_ senderID: String) -> Bool {
        !seenSenders().contains(senderID)
    }

    static func markSenderSeen(_ senderID: String) {
        var seen = seenSenders()
        guard !seen.contains(senderID) else { return }
        seen.insert(senderID)
        UserDefaults(suiteName: GridStore.appGroupID)?.set(Array(seen), forKey: seenSendersKey)
    }

    private static func seenSenders() -> Set<String> {
        let group = UserDefaults(suiteName: GridStore.appGroupID)
        if let stored = group?.array(forKey: seenSendersKey) as? [String] { return Set(stored) }
        // Migrate the pre-extension location, else seed from history (upgrade path).
        let seeded = (UserDefaults.standard.array(forKey: seenSendersKey) as? [String]).map(Set.init)
            ?? Set(GridStore.shared.receivedHistory().map(\.senderID))
        group?.set(Array(seeded), forKey: seenSendersKey)
        UserDefaults.standard.removeObject(forKey: seenSendersKey)
        return seeded
    }
}
