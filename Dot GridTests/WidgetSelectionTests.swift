//
//  WidgetSelectionTests.swift
//  Dot GridTests
//
//  The widget's hard content contract: received-only, latest-by-server-time, and
//  exact per-friend selection with no cross-friend fallback.
//

import Foundation
import Testing
@testable import Dot_Grid

@Suite(.serialized)
struct WidgetSelectionTests {
    private let me = Profile(id: "me", name: "me", token: .placeholder)
    private let friendA = FriendInfo(id: "friend-a#phone", name: "a", token: .placeholder)
    private let friendB = FriendInfo(id: "friend-b#phone", name: "b", token: .placeholder)

    private func drawing(senderID: String, messageID: String, at: TimeInterval) -> DisplayDrawing {
        .dots(
            .empty,
            senderID: senderID,
            senderName: senderID,
            token: .placeholder,
            sentAt: Date(timeIntervalSinceReferenceDate: at),
            messageID: messageID
        )
    }

    @Test func ownAccountDrawingIsRejectedAtTheStoreBoundary() {
        let store = GridStore.shared
        store.clearSharedState()
        defer { store.clearSharedState() }
        store.saveProfile(me)
        store.saveRoster([friendA])

        let accepted = store.saveReceived(
            drawing(senderID: "me#other-device", messageID: "own", at: 100)
        )

        #expect(!accepted)
        #expect(store.latestDisplayDrawing() == nil)
        #expect(store.receivedHistory().isEmpty)
    }

    @Test func latestWidgetUsesNewestFriendAndPinnedWidgetUsesOnlyItsFriend() {
        let store = GridStore.shared
        store.clearSharedState()
        defer { store.clearSharedState() }
        store.saveProfile(me)
        store.saveRoster([friendA, friendB])

        let olderA = drawing(senderID: friendA.id, messageID: "a1", at: 100)
        let newerB = drawing(senderID: friendB.id, messageID: "b1", at: 200)
        #expect(store.saveReceived(olderA))
        #expect(store.saveReceived(newerB))

        #expect(store.latestDisplayDrawing()?.messageID == "b1")
        #expect(store.displayDrawing(forFriend: friendA.id)?.messageID == "a1")
        #expect(store.displayDrawing(forFriend: friendB.id)?.messageID == "b1")
    }

    @Test func PinnedFriendWithoutAMessageDoesNotFallBackToSomeoneElse() {
        let store = GridStore.shared
        store.clearSharedState()
        defer { store.clearSharedState() }
        store.saveProfile(me)
        store.saveRoster([friendA, friendB])
        #expect(store.saveReceived(
            drawing(senderID: friendA.id, messageID: "a1", at: 100)
        ))

        #expect(store.displayDrawing(forFriend: friendB.id) == nil)
        #expect(store.latestDisplayDrawing()?.senderID == friendA.id)
    }
}
