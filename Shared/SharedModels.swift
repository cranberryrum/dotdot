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

/// Geometry the photo frame and widget image share, so framing is WYSIWYG.
enum WidgetMetrics {
    /// systemLarge is close to square; a square frame center-crops gracefully.
    static let aspect: CGFloat = 1.0
    /// systemLarge is a touch taller than wide (≈0.95 across iPhones). Doodles are
    /// drawn AND baked at this ratio so the canvas matches the widget exactly — the
    /// doodle fills it end-to-end with no crop (no square-in-tall-frame letterbox).
    static let doodleAspect: CGFloat = 338.0 / 354.0   // width : height
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

    init(kind: MessageKind, grid: Grid? = nil, imageData: Data? = nil,
         senderID: String, senderName: String, token: IdentityToken, sentAt: Date) {
        self.kind = kind
        self.grid = grid
        self.imageData = imageData
        self.senderID = senderID
        self.senderName = senderName
        self.token = token
        self.sentAt = sentAt
    }

    static func dots(_ grid: Grid, senderID: String, senderName: String,
                     token: IdentityToken, sentAt: Date) -> DisplayDrawing {
        DisplayDrawing(kind: .dots, grid: grid, senderID: senderID,
                       senderName: senderName, token: token, sentAt: sentAt)
    }

    static func photo(_ imageData: Data, senderID: String, senderName: String,
                      token: IdentityToken, sentAt: Date) -> DisplayDrawing {
        DisplayDrawing(kind: .photo, imageData: imageData, senderID: senderID,
                       senderName: senderName, token: token, sentAt: sentAt)
    }

    static func doodle(_ imageData: Data, senderID: String, senderName: String,
                       token: IdentityToken, sentAt: Date) -> DisplayDrawing {
        DisplayDrawing(kind: .doodle, imageData: imageData, senderID: senderID,
                       senderName: senderName, token: token, sentAt: sentAt)
    }

    // Tolerant decode: older cached records had no `kind` and a required `grid`.
    enum CodingKeys: String, CodingKey { case kind, grid, imageData, senderID, senderName, token, sentAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(MessageKind.self, forKey: .kind)) ?? .dots
        grid = try? c.decode(Grid.self, forKey: .grid)
        imageData = try? c.decode(Data.self, forKey: .imageData)
        senderID = (try? c.decode(String.self, forKey: .senderID)) ?? ""
        senderName = (try? c.decode(String.self, forKey: .senderName)) ?? "Friend"
        token = (try? c.decode(IdentityToken.self, forKey: .token)) ?? .placeholder
        sentAt = (try? c.decode(Date.self, forKey: .sentAt)) ?? Date()
    }
}

/// A dotdot you sent, kept for the inbox's "sent" feed. Reuses `DisplayDrawing` for
/// the payload (its `senderID` is empty — it's yours) and records who it went to.
/// `recipients` is empty for a local-only send (no friends picked).
struct SentMessage: Codable, Equatable, Identifiable {
    var id: String
    var drawing: DisplayDrawing
    var recipients: [FriendInfo]

    var sentAt: Date { drawing.sentAt }
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
}
