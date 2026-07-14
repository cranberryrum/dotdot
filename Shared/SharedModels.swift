//
//  SharedModels.swift
//  Dot Grid
//
//  Plain Codable types shared by the app and the widget. No CloudKit here —
//  the widget does not link CloudKit; it only reads the App Group via GridStore.
//

import SwiftUI

/// A person's visual identity: one emoji or initial on a palette color.
struct IdentityToken: Codable, Equatable, Hashable {
    var symbol: String      // a single emoji or letter
    var colorIndex: Int     // index into Palette.entries

    var color: Color { Palette.color(at: colorIndex) }

    var prefersDarkText: Bool {
        Palette.entries.indices.contains(colorIndex) ? Palette.entries[colorIndex].prefersDarkText : false
    }

    static let placeholder = IdentityToken(symbol: "✦", colorIndex: 0)
}

/// The local user's identity. `id` is the CloudKit user record name, so it
/// follows the iCloud account across devices. No personal data beyond a name.
struct Profile: Codable, Equatable {
    var id: String
    var name: String
    var token: IdentityToken
}

/// A paired friend, cached locally so the widget's friend picker works offline.
struct FriendInfo: Codable, Equatable, Identifiable, Hashable {
    var id: String          // friend's addressable participant ID
    var name: String
    var token: IdentityToken
}

/// What a message carries: a dot-grid, a photo, or a freehand doodle. Doodles
/// transport as a JPEG like photos, but the widget fits (not fills) them so they
/// never crop at the edges.
enum MessageKind: String, Codable { case dots, photo, doodle }

/// Geometry the composer boards and the widget image share, so framing is WYSIWYG.
enum WidgetMetrics {
    /// All three composer boards (dots, photo, doodle) are square, so they're the
    /// same size across tabs. systemLarge is close to square, so a square source
    /// center-crops (photo, edge-to-edge) or fits (doodle, invisible letterbox).
    static let aspect: CGFloat = 1.0
    /// Roughly systemLarge points × 3. The widget must never load more than this.
    static let targetPixels: CGFloat = 1100
}

/// A message as displayed on the widget, tagged with who it's from. Holds either
/// a dot-grid (`grid`) or a downscaled, widget-safe JPEG (`imageData`).
struct DisplayDrawing: Codable, Equatable {
    var kind: MessageKind
    var grid: Grid?
    var imageData: Data?
    var senderID: String
    var senderName: String
    var token: IdentityToken
    var sentAt: Date
    /// Stable cross-device ID (the sender's local send UUID, carried on the Drawing
    /// record) — what a reaction points at. nil on dotdots sent before reactions.
    var messageID: String?
    /// The emoji I reacted with to this RECEIVED dotdot (local; badges the widget).
    var myReaction: String?

    init(kind: MessageKind, grid: Grid? = nil, imageData: Data? = nil,
         senderID: String, senderName: String, token: IdentityToken, sentAt: Date,
         messageID: String? = nil, myReaction: String? = nil) {
        self.kind = kind
        self.grid = grid
        self.imageData = imageData
        self.senderID = senderID
        self.senderName = senderName
        self.token = token
        self.sentAt = sentAt
        self.messageID = messageID
        self.myReaction = myReaction
    }

    static func dots(_ grid: Grid, senderID: String, senderName: String,
                     token: IdentityToken, sentAt: Date, messageID: String? = nil) -> DisplayDrawing {
        DisplayDrawing(kind: .dots, grid: grid, senderID: senderID,
                       senderName: senderName, token: token, sentAt: sentAt, messageID: messageID)
    }

    static func photo(_ imageData: Data, senderID: String, senderName: String,
                      token: IdentityToken, sentAt: Date, messageID: String? = nil) -> DisplayDrawing {
        DisplayDrawing(kind: .photo, imageData: imageData, senderID: senderID,
                       senderName: senderName, token: token, sentAt: sentAt, messageID: messageID)
    }

    static func doodle(_ imageData: Data, senderID: String, senderName: String,
                       token: IdentityToken, sentAt: Date, messageID: String? = nil) -> DisplayDrawing {
        DisplayDrawing(kind: .doodle, imageData: imageData, senderID: senderID,
                       senderName: senderName, token: token, sentAt: sentAt, messageID: messageID)
    }

    // Tolerant decode: older cached records had no `kind` and a required `grid`.
    enum CodingKeys: String, CodingKey {
        case kind, grid, imageData, senderID, senderName, token, sentAt, messageID, myReaction
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(MessageKind.self, forKey: .kind)) ?? .dots
        grid = try? c.decode(Grid.self, forKey: .grid)
        imageData = try? c.decode(Data.self, forKey: .imageData)
        senderID = (try? c.decode(String.self, forKey: .senderID)) ?? ""
        senderName = (try? c.decode(String.self, forKey: .senderName)) ?? "Friend"
        token = (try? c.decode(IdentityToken.self, forKey: .token)) ?? .placeholder
        sentAt = (try? c.decode(Date.self, forKey: .sentAt)) ?? Date()
        messageID = try? c.decode(String.self, forKey: .messageID)
        myReaction = try? c.decode(String.self, forKey: .myReaction)
    }
}

/// One friend's emoji reaction to a dotdot you sent — shown on the sent feed.
struct ReactionInfo: Codable, Equatable, Identifiable {
    var emoji: String
    var reactorID: String
    var reactorName: String
    var at: Date

    var id: String { reactorID }   // one reaction per person; a new one replaces
}

/// A dotdot you sent, kept for the inbox's "sent" feed. Reuses `DisplayDrawing` for
/// the payload (its `senderID` is empty — it's yours) and records who it went to.
/// `recipients` is empty for a local-only send (no friends picked).
struct SentMessage: Codable, Equatable, Identifiable {
    var id: String
    var drawing: DisplayDrawing
    var recipients: [FriendInfo]
    /// Emoji reactions from recipients, newest state per person.
    var reactions: [ReactionInfo] = []

    var sentAt: Date { drawing.sentAt }

    init(id: String, drawing: DisplayDrawing, recipients: [FriendInfo], reactions: [ReactionInfo] = []) {
        self.id = id
        self.drawing = drawing
        self.recipients = recipients
        self.reactions = reactions
    }

    // Tolerant decode: history saved before reactions shipped has no `reactions` key.
    enum CodingKeys: String, CodingKey { case id, drawing, recipients, reactions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        drawing = try c.decode(DisplayDrawing.self, forKey: .drawing)
        recipients = (try? c.decode([FriendInfo].self, forKey: .recipients)) ?? []
        reactions = (try? c.decode([ReactionInfo].self, forKey: .reactions)) ?? []
    }
}

/// A send that still needs to reach CloudKit (offline / retrying). Persisted so a
/// message is never lost to a network hiccup.
struct QueuedSend: Codable, Equatable, Identifiable {
    var id: String          // local uuid string
    var kind: MessageKind
    var grid: Grid?
    var imageData: Data?    // downscaled widget-safe JPEG for photo sends
    var recipientIDs: [String]
    var senderName: String
    var token: IdentityToken
    var createdAt: Date
    /// Flush attempts so far — the retry machinery gives up at a cap instead of
    /// hammering forever; the debug panel shows it so a stuck queue is diagnosable.
    var attempts: Int = 0
    /// The last send error, human-readable — surfaced in the debug panel.
    var lastErrorDescription: String?
}

extension QueuedSend {
    // Tolerant decode (in an extension, so the memberwise init survives): queued
    // blobs persisted before attempts/lastErrorDescription existed must still load.
    enum CodingKeys: String, CodingKey {
        case id, kind, grid, imageData, recipientIDs, senderName, token, createdAt,
             attempts, lastErrorDescription
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(MessageKind.self, forKey: .kind)) ?? .dots
        grid = try? c.decode(Grid.self, forKey: .grid)
        imageData = try? c.decode(Data.self, forKey: .imageData)
        recipientIDs = (try? c.decode([String].self, forKey: .recipientIDs)) ?? []
        senderName = (try? c.decode(String.self, forKey: .senderName)) ?? ""
        token = (try? c.decode(IdentityToken.self, forKey: .token)) ?? .placeholder
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        attempts = (try? c.decode(Int.self, forKey: .attempts)) ?? 0
        lastErrorDescription = try? c.decode(String.self, forKey: .lastErrorDescription)
    }
}
