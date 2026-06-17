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
    /// Long random token embedded in the user's shareable invite link.
    var inviteToken: String
}

/// A paired friend, cached locally so the widget's friend picker works offline.
struct FriendInfo: Codable, Equatable, Identifiable, Hashable {
    var id: String          // friend's CloudKit user record name
    var name: String
    var token: IdentityToken
}

/// A drawing as displayed on the widget, tagged with who it's from.
struct DisplayDrawing: Codable, Equatable {
    var grid: Grid
    var senderID: String
    var senderName: String
    var token: IdentityToken
    var sentAt: Date
}

/// A send that still needs to reach CloudKit (offline / retrying). Persisted so a
/// drawing is never lost to a network hiccup.
struct QueuedSend: Codable, Equatable, Identifiable {
    var id: String          // local uuid string
    var grid: Grid
    var recipientIDs: [String]
    var senderName: String
    var token: IdentityToken
    var createdAt: Date
}
