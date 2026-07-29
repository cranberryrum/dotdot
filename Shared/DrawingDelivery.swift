//
//  DrawingDelivery.swift
//  Dot Grid
//
//  The shared Drawing-record decoder. The app, the widget, and the notification
//  service extension each turn a CKRecord into a DisplayDrawing at some point —
//  keeping that ONE decode here prevents the three from drifting apart on what
//  a record's fields mean.
//

import CloudKit
import Foundation

enum ParticipantIdentity {
    /// A participant is either a legacy CloudKit user-record name or the current
    /// `<user-record-name>#<device-id>` address. Both belong to the same account.
    nonisolated static func accountID(from participantID: String) -> String {
        participantID.split(separator: "#", maxSplits: 1).first.map(String.init) ?? participantID
    }

    nonisolated static func belongsToAccount(_ participantID: String, userID: String) -> Bool {
        accountID(from: participantID) == userID
    }
}

enum DrawingRecordDecoder {
    /// Decode one complete Drawing record. `sentAt` is the sender device's clock
    /// (transport identity); `serverCreatedAt` is CloudKit's server-authored time,
    /// which `DisplayDrawing.orderingDate` prefers for stable ordering across
    /// friends' disagreeing clocks.
    nonisolated static func drawing(from record: CKRecord) -> DisplayDrawing? {
        let senderID = record["senderID"] as? String ?? ""
        guard !senderID.isEmpty else { return nil }

        let sentAt = (record["sentAt"] as? Date) ?? record.creationDate ?? Date()
        let senderName = record["senderName"] as? String ?? "Friend"
        let token = IdentityToken(
            symbol: record["tokenSymbol"] as? String ?? "✦",
            colorIndex: record["tokenColor"] as? Int ?? 0
        )
        let kind = MessageKind(rawValue: record["kind"] as? String ?? "dots") ?? .dots
        let messageID = record["messageID"] as? String
        let avatarJPEG = record["avatarData"] as? Data
        let serverCreatedAt = record.creationDate
        let recordName = record.recordID.recordName

        switch kind {
        case .photo, .doodle:
            guard let asset = record["imageAsset"] as? CKAsset,
                  let url = asset.fileURL,
                  let data = try? Data(contentsOf: url) else { return nil }
            return kind == .doodle
                ? .doodle(data, senderID: senderID, senderName: senderName, token: token,
                          sentAt: sentAt, messageID: messageID, serverCreatedAt: serverCreatedAt,
                          recordName: recordName, avatarJPEG: avatarJPEG)
                : .photo(data, senderID: senderID, senderName: senderName, token: token,
                         sentAt: sentAt, messageID: messageID, serverCreatedAt: serverCreatedAt,
                         recordName: recordName, avatarJPEG: avatarJPEG)
        case .dots:
            guard let data = record["gridData"] as? Data,
                  let grid = try? JSONDecoder().decode(Grid.self, from: data) else { return nil }
            return .dots(grid, senderID: senderID, senderName: senderName, token: token,
                         sentAt: sentAt, messageID: messageID, serverCreatedAt: serverCreatedAt,
                         recordName: recordName, avatarJPEG: avatarJPEG)
        }
    }
}
