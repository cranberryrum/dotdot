//
//  NotificationService.swift
//  DotGridNotificationService
//
//  Rewrites the visible CloudKit pushes into house-style banners AND lands the
//  payload before the user even unlocks: fetch the record, write it to the App
//  Group exactly like the app's fetch path would, and reload the widget. Runs
//  even when the app is force-quit — that's the whole point.
//
//  Budget-aware: the banner copy is built from the push's desiredKeys FIRST, so
//  if the record (or its photo asset) can't download in the ~30s window, the
//  correct banner still ships and the app's fetch paths remain the safety net.
//  The fetch high-water mark is deliberately never advanced here — the app's
//  fetch stays the source of truth, and GridStore.saveReceived is idempotent so
//  the overlap costs nothing.
//

import CloudKit
import UserNotifications
import WidgetKit

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var ingestTask: Task<Void, Never>?

    private let container = CKContainer(identifier: "iCloud.com.kolteaditya.dotgrid")

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        contentHandler = handler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        bestAttempt = content

        guard let note = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo)
                as? CKQueryNotification else {
            handler(content)
            return
        }

        let subscriptionID = note.subscriptionID ?? ""
        let fields = note.recordFields ?? [:]

        if subscriptionID.hasPrefix("drawings-to-") {
            prepareDrawingBanner(content, fields: fields)
            ingestTask = Task { [weak self] in
                await self?.ingestDrawing(recordID: note.recordID)
                self?.finish()
            }
        } else if subscriptionID.hasPrefix("reactions-to-") {
            prepareReactionBanner(content, fields: fields)
            ingestTask = Task { [weak self] in
                await self?.ingestReaction(recordID: note.recordID)
                self?.finish()
            }
        } else {
            handler(content)
        }
    }

    /// Out of time: the banner (already correct from desiredKeys) ships as-is;
    /// whatever the ingest didn't finish, the app's next fetch reconciles.
    override func serviceExtensionTimeWillExpire() {
        ingestTask?.cancel()
        finish()
    }

    private func finish() {
        guard let handler = contentHandler, let content = bestAttempt else { return }
        contentHandler = nil
        handler(content)
    }

    // MARK: Banners (from the push payload — no fetch required)

    private func prepareDrawingBanner(_ content: UNMutableNotificationContent,
                                      fields: [CKRecord.FieldKey: Any]) {
        let senderName = fields["senderName"] as? String ?? ""
        let senderID = fields["senderID"] as? String ?? ""
        let kind = MessageKind(rawValue: fields["kind"] as? String ?? "") ?? .dots
        let firstEver = !senderID.isEmpty && PushCopy.isFirstFromSender(senderID)

        content.title = ""   // the app name reads as the title
        content.body = PushCopy.drawingBody(kind: kind, senderName: senderName,
                                            firstFromSender: firstEver)
        if !senderID.isEmpty {
            content.threadIdentifier = "drawings-\(senderID)"
            if let sentAt = fields["sentAt"] as? Date {
                content.userInfo = NotificationRoute
                    .receivedDrawing(senderID: senderID, sentAt: sentAt).userInfo
            }
            PushCopy.markSenderSeen(senderID)
        }
    }

    private func prepareReactionBanner(_ content: UNMutableNotificationContent,
                                       fields: [CKRecord.FieldKey: Any]) {
        let reactorName = fields["reactorName"] as? String ?? ""
        content.title = ""
        content.body = PushCopy.reactionBody(reactorName: reactorName)
        if let messageID = fields["messageID"] as? String {
            content.threadIdentifier = "reactions-\(messageID)"
            content.userInfo = NotificationRoute.sentDrawing(messageID: messageID).userInfo
        }
    }

    // MARK: Ingest (same decode + write the app's fetch path does)

    private func ingestDrawing(recordID: CKRecord.ID?) async {
        guard let recordID,
              let record = try? await container.publicCloudDatabase.record(for: recordID) else { return }

        let sentAt = (record["sentAt"] as? Date) ?? Date()
        let senderID = record["senderID"] as? String ?? ""
        let senderName = record["senderName"] as? String ?? "Friend"
        let token = IdentityToken(
            symbol: record["tokenSymbol"] as? String ?? "✦",
            colorIndex: record["tokenColor"] as? Int ?? 0
        )
        let kind = MessageKind(rawValue: record["kind"] as? String ?? "dots") ?? .dots
        let messageID = record["messageID"] as? String

        let drawing: DisplayDrawing
        switch kind {
        case .photo, .doodle:
            guard let asset = record["imageAsset"] as? CKAsset,
                  let url = asset.fileURL,
                  let data = try? Data(contentsOf: url) else { return }
            drawing = kind == .doodle
                ? .doodle(data, senderID: senderID, senderName: senderName, token: token,
                          sentAt: sentAt, messageID: messageID)
                : .photo(data, senderID: senderID, senderName: senderName, token: token,
                         sentAt: sentAt, messageID: messageID)
        case .dots:
            guard let data = record["gridData"] as? Data,
                  let grid = try? JSONDecoder().decode(Grid.self, from: data) else { return }
            drawing = .dots(grid, senderID: senderID, senderName: senderName, token: token,
                            sentAt: sentAt, messageID: messageID)
        }
        GridStore.shared.saveReceived(drawing)   // idempotent vs the app's own fetch
        WidgetCenter.shared.reloadAllTimelines() // the reveal happens on the widget
    }

    private func ingestReaction(recordID: CKRecord.ID?) async {
        guard let recordID,
              let record = try? await container.publicCloudDatabase.record(for: recordID),
              let emoji = record["emoji"] as? String,
              let reactorID = record["reactorID"] as? String else { return }
        let reaction = ReactionInfo(
            emoji: emoji,
            reactorID: reactorID,
            reactorName: record["reactorName"] as? String ?? "friend",
            at: (record["sentAt"] as? Date) ?? Date()
        )
        GridStore.shared.applyIncomingReaction(
            reaction,
            messageID: record["messageID"] as? String,
            drawingSentAt: (record["drawingSentAt"] as? Date) ?? .distantPast
        )
        // No widget reload: reactions live on the sent feed, not the widget.
    }
}
