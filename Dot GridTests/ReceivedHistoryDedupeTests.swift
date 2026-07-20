//
//  ReceivedHistoryDedupeTests.swift
//  Dot GridTests
//
//  The received feed's twin-healing: the app's fetch and the notification
//  service extension race read-modify-write on the same App Group array, so
//  duplicates can land despite the prepend-time check. Duplicate rows collide
//  in the feed's ForEach identity (ghost/blank cards), so the store collapses
//  them on read.
//

import Foundation
import Testing
@testable import Dot_Grid

struct ReceivedHistoryDedupeTests {

    private func drawing(sender: String = "f1", at seconds: TimeInterval = 700_000_000,
                         messageID: String? = nil, reaction: String? = nil) -> DisplayDrawing {
        DisplayDrawing(kind: .dots, grid: .empty, senderID: sender, senderName: "maya",
                       token: .placeholder, sentAt: Date(timeIntervalSinceReferenceDate: seconds),
                       messageID: messageID, myReaction: reaction)
    }

    @Test func twinsByMessageIDCollapse() {
        let items = [drawing(messageID: "m1"), drawing(messageID: "m1")]
        #expect(GridStore.dedupingReceived(items).count == 1)
    }

    @Test func twinsBySenderAndTimeCollapse() {
        // A stored copy from before messageID shipped (nil) + its refetched twin
        // (carrying one) are the same drawing — sender + exact sentAt says so.
        let items = [drawing(messageID: nil), drawing(messageID: "m1")]
        #expect(GridStore.dedupingReceived(items).count == 1)
    }

    @Test func distinctDrawingsSurvive() {
        let items = [
            drawing(sender: "f1", at: 1000, messageID: "m1"),
            drawing(sender: "f1", at: 2000, messageID: "m2"),
            drawing(sender: "f2", at: 1000, messageID: "m3"),
            drawing(sender: "f3", at: 3000),   // no messageID at all
        ]
        let cleaned = GridStore.dedupingReceived(items)
        #expect(cleaned.count == 4)
        // Order preserved (newest-first storage order must survive the pass).
        #expect(cleaned.map(\.messageID) == ["m1", "m2", "m3", nil])
    }

    @Test func reactionOnALaterTwinIsKept() {
        // The reaction was stamped on the copy that got pushed deeper by the
        // duplicate — collapsing must not lose it.
        let items = [drawing(messageID: "m1"), drawing(messageID: "m1", reaction: "❤️")]
        let cleaned = GridStore.dedupingReceived(items)
        #expect(cleaned.count == 1)
        #expect(cleaned[0].myReaction == "❤️")
    }
}
