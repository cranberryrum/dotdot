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
                         messageID: String? = nil, reaction: String? = nil,
                         serverAt serverSeconds: TimeInterval? = nil,
                         recordName: String? = nil) -> DisplayDrawing {
        DisplayDrawing(kind: .dots, grid: .empty, senderID: sender, senderName: "maya",
                       token: .placeholder, sentAt: Date(timeIntervalSinceReferenceDate: seconds),
                       messageID: messageID, myReaction: reaction,
                       serverCreatedAt: serverSeconds.map(Date.init(timeIntervalSinceReferenceDate:)),
                       recordName: recordName)
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

    @Test func twinsByExactCloudKitRecordNameCollapseDespiteDifferentClientFields() {
        let items = [
            drawing(sender: "f1", at: 1000, messageID: nil, recordName: "drawing-exact"),
            drawing(sender: "f1", at: 1001, messageID: "m1", recordName: "drawing-exact"),
        ]
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

    // MARK: Ordered insertion (lookback refetches must not jump the queue)

    @Test func lateArrivalInsertsAtItsTruePosition() {
        // Feed is newest-first; a drawing older than the top but newer than the
        // bottom belongs in the middle.
        let feed = [drawing(at: 3000), drawing(at: 1000)]
        #expect(GridStore.insertionIndex(for: drawing(at: 2000), in: feed) == 1)
    }

    @Test func newestInsertsAtTheTopAndOldestAtTheEnd() {
        let feed = [drawing(at: 3000), drawing(at: 1000)]
        #expect(GridStore.insertionIndex(for: drawing(at: 4000), in: feed) == 0)
        #expect(GridStore.insertionIndex(for: drawing(at: 500), in: feed) == 2)
    }

    @Test func insertionUsesServerClockInsteadOfSkewedSenderClock() {
        // The middle record's sender clock says it is newest, but CloudKit says it
        // was created between the other two. The feed must follow the server.
        let feed = [
            drawing(at: 9_000, serverAt: 3_000),
            drawing(at: 1_000, serverAt: 1_000),
        ]
        let skewed = drawing(at: 99_000, serverAt: 2_000)
        #expect(GridStore.insertionIndex(for: skewed, in: feed) == 1)
    }

    // MARK: Default widget projection

    @Test func defaultWidgetIsEmptyUntilAFriendSends() {
        #expect(GridStore.defaultWidgetDrawing(received: nil) == nil)
    }

    @Test func defaultWidgetShowsTheReceivedProjection() {
        let received = drawing(at: 100, serverAt: 3_000, recordName: "received-newer")
        let selected = GridStore.defaultWidgetDrawing(received: received)
        #expect(selected?.recordName == "received-newer")
        #expect(selected?.senderID == "f1")
    }

    @Test func widgetProjectionUsesServerClockInsteadOfSenderClock() {
        let senderClockLooksNew = drawing(at: 50_000, serverAt: 1_000, recordName: "older")
        let serverNewer = drawing(at: 100, serverAt: 2_000, recordName: "newer")
        #expect(GridStore.newestForWidget(in: [senderClockLooksNew, serverNewer])?.recordName == "newer")
    }

    @Test func widgetProjectionBreaksEqualServerTimesByRecordIdentity() {
        let first = drawing(at: 100, serverAt: 2_000, recordName: "drawing-a")
        let second = drawing(at: 100, serverAt: 2_000, recordName: "drawing-b")
        #expect(GridStore.newestForWidget(in: [first, second])?.recordName == "drawing-b")
        #expect(GridStore.prefersForWidget(second, over: first))
    }

    @Test func senderTimeKeyMatchesAcrossConstructions() {
        // The fetch layer's already-have check and the dedupe pass must agree on
        // identity for the same (sender, sentAt) pair.
        let at = Date(timeIntervalSinceReferenceDate: 700_000_000.123456)
        #expect(GridStore.senderTimeKey(senderID: "f1", sentAt: at)
             == GridStore.senderTimeKey(senderID: "f1", sentAt: Date(timeIntervalSinceReferenceDate: 700_000_000.123456)))
        #expect(GridStore.senderTimeKey(senderID: "f1", sentAt: at)
             != GridStore.senderTimeKey(senderID: "f2", sentAt: at))
    }
}
