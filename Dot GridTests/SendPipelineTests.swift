//
//  SendPipelineTests.swift
//  Dot GridTests
//
//  The send pipeline's testable core: the retry/give-up policy (pure), and the
//  tolerant decoding that keeps queued/history blobs from older builds loading.
//

import Foundation
import Testing
@testable import Dot_Grid

struct SendPipelineTests {

    // MARK: Flush transitions (success / partial / terminal / durable retry)

    private func result(failed: [String] = [], terminal: Bool = false) -> SharingService.SendResult {
        SharingService.SendResult(failedRecipientIDs: failed, lastError: nil, isTerminal: terminal)
    }

    @Test func successGoesSent() {
        #expect(AppModel.flushOutcome(after: result(), attemptsSoFar: 0) == .sent)
        // Even at the cap, a success is a success.
        #expect(AppModel.flushOutcome(after: result(), attemptsSoFar: 99) == .sent)
    }

    @Test func partialFailureKeepsRetryingWithFailedIDs() {
        let outcome = AppModel.flushOutcome(after: result(failed: ["b"]), attemptsSoFar: 0)
        #expect(outcome == .retrying(failedRecipientIDs: ["b"], attempts: 1))
    }

    @Test func terminalErrorGivesUpImmediately() {
        let outcome = AppModel.flushOutcome(after: result(failed: ["a", "b"], terminal: true),
                                            attemptsSoFar: 0)
        #expect(outcome == .gaveUp(failedRecipientIDs: ["a", "b"]))
    }

    @Test func transientFailureNeverAgesOutOfTheOutbox() {
        // A phone can be offline for days. Attempts are diagnostic/backoff state,
        // not a reason to destroy a message that CloudKit may still accept later.
        let outcome = AppModel.flushOutcome(after: result(failed: ["a"]),
                                            attemptsSoFar: 10_000)
        #expect(outcome == .retrying(failedRecipientIDs: ["a"], attempts: 10_001))
    }

    // MARK: Stable server identity

    @Test func drawingRecordNameIsStableAcrossRetriesAndScopedPerRecipient() {
        let first = SharingService.drawingRecordName(messageID: "message-1", recipientID: "friend#one")
        let retry = SharingService.drawingRecordName(messageID: "message-1", recipientID: "friend#one")
        let anotherRecipient = SharingService.drawingRecordName(messageID: "message-1", recipientID: "friend#two")
        let anotherMessage = SharingService.drawingRecordName(messageID: "message-2", recipientID: "friend#one")

        #expect(first == retry)
        #expect(first != anotherRecipient)
        #expect(first != anotherMessage)
    }

    // MARK: Tolerant decoding (blobs persisted by older builds must still load)

    @Test func oldSentMessageDecodesAsSent() throws {
        // Pre-status, pre-reactions shape with a recipient → reads as .sent.
        let json = """
        {"id":"m1",
         "drawing":{"kind":"dots","senderID":"","senderName":"me",
                    "token":{"symbol":"✦","colorIndex":0},"sentAt":700000000},
         "recipients":[{"id":"f1","name":"maya","token":{"symbol":"🦊","colorIndex":1}}]}
        """.data(using: .utf8)!
        let message = try JSONDecoder().decode(SentMessage.self, from: json)
        #expect(message.status == .sent)
        #expect(message.failedRecipientIDs.isEmpty)
        #expect(message.reactions.isEmpty)
    }

    @Test func oldLocalOnlySentMessageDecodesAsLocalOnly() throws {
        let json = """
        {"id":"m2",
         "drawing":{"kind":"dots","senderID":"","senderName":"me",
                    "token":{"symbol":"✦","colorIndex":0},"sentAt":700000000},
         "recipients":[]}
        """.data(using: .utf8)!
        let message = try JSONDecoder().decode(SentMessage.self, from: json)
        #expect(message.status == .localOnly)
    }

    @Test func storedStatusWinsOverInference() throws {
        let json = """
        {"id":"m3",
         "drawing":{"kind":"dots","senderID":"","senderName":"me",
                    "token":{"symbol":"✦","colorIndex":0},"sentAt":700000000},
         "recipients":[{"id":"f1","name":"maya","token":{"symbol":"🦊","colorIndex":1}}],
         "status":"failed","failedRecipientIDs":["f1"]}
        """.data(using: .utf8)!
        let message = try JSONDecoder().decode(SentMessage.self, from: json)
        #expect(message.status == .failed)
        #expect(message.failedRecipientIDs == ["f1"])
    }

    @Test func oldQueuedSendDecodesWithZeroAttempts() throws {
        // Pre-attempts shape, exactly what an older build left in the outbox.
        // (grid omitted — it's optional and its own coding is covered elsewhere.)
        let json = """
        {"id":"q1","kind":"dots",
         "recipientIDs":["f1"],"senderName":"me",
         "token":{"symbol":"✦","colorIndex":0},"createdAt":700000000}
        """.data(using: .utf8)!
        let queued = try JSONDecoder().decode(QueuedSend.self, from: json)
        #expect(queued.attempts == 0)
        #expect(queued.lastErrorDescription == nil)
        #expect(queued.recipientIDs == ["f1"])
    }

    @Test func queuedSendRoundTripsAttempts() throws {
        var queued = QueuedSend(id: "q2", kind: .dots, grid: nil, imageData: nil,
                                recipientIDs: ["f1"], senderName: "me",
                                token: .placeholder, createdAt: Date())
        queued.attempts = 3
        queued.lastErrorDescription = "network unavailable"
        let data = try JSONEncoder().encode(queued)
        let decoded = try JSONDecoder().decode(QueuedSend.self, from: data)
        #expect(decoded.attempts == 3)
        #expect(decoded.lastErrorDescription == "network unavailable")
    }
}
