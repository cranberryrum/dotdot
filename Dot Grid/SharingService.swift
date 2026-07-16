//
//  SharingService.swift
//  Dot Grid
//
//  All CloudKit access lives here. Identity is the iCloud user record (no login,
//  no accounts). Everything is in the PUBLIC database, keyed by user record names,
//  so two friends can find each other by ID. Drawings are tiny (~1 KB) Data blobs.
//
//  Required CloudKit Dashboard schema (development env auto-creates record types
//  on first save, but you MUST add these indexes by hand):
//    • Profile     recordName=<userID>   fields: name, tokenSymbol, tokenColor
//    • Friendship  recordName="pair_<a>__<b>"  fields: members [String] (QUERYABLE)
//    • InviteCode  fields: code (QUERYABLE), ownerID, expiresAt, used
//    • Drawing     fields: recipientID (QUERYABLE), sentAt (SORTABLE/QUERYABLE),
//                  senderID, senderName, tokenSymbol, tokenColor, gridData
//
//  Subscriptions (created from code; deploy the schema to Production before any
//  TestFlight build or the -v2 subscriptions will not exist for prod users):
//    • drawings-to-<id>-v2   Drawing, recipientID == me. VISIBLE when the drawings
//      alert toggle is on: alertLocalizationKey PUSH_DRAWING (args senderName),
//      sound dotdot.caf, mutable content (rewritten by DotGridNotificationService),
//      desiredKeys senderName/kind/senderID/sentAt/messageID; silent when off.
//      Always shouldSendContentAvailable so the live app still wakes to fetch.
//    • reactions-to-<id>-v2  Reaction, recipientID == me, creation + update.
//      Same shape; localization key PUSH_REACTION (args reactorName), default sound.
//    • friendships-of-<id>   Friendship, members CONTAINS me. Stays silent; the
//      connected banner is posted locally (owner-only + once-per-friendship logic).
//    The v1 silent drawing/reaction subscription IDs are deleted on ensure.
//

import CloudKit
import Foundation
import UIKit

enum PairingError: LocalizedError {
    case codeExpired
    case codeUsed
    case codeNotFound
    case ownCode
    case alreadyFriends
    case rateLimited
    case notSignedIn
    case generic

    var errorDescription: String? {
        switch self {
        case .codeExpired:    "That code expired — ask for a fresh one."
        case .codeUsed:       "That code's already been used."
        case .codeNotFound:   "We couldn't find that code."
        case .ownCode:        "That's your own code."
        case .alreadyFriends: "You two are already connected."
        case .rateLimited:    "Too many tries — give it a minute and try again."
        case .notSignedIn:    "Sign into iCloud to add friends."
        case .generic:        "Something went wrong. Try again."
        }
    }
}

/// Result of checking the iCloud account.
enum AccountState: Equatable {
    case available(userID: String)
    case noAccount
    case restricted
    case unknown
}

final class SharingService {
    static let shared = SharingService()

    private let container = CKContainer(identifier: "iCloud.com.kolteaditya.dotgrid")
    private var db: CKDatabase { container.publicCloudDatabase }

    // Record types
    private enum RT {
        static let profile = "Profile"
        static let friendship = "Friendship"
        static let inviteCode = "InviteCode"
        static let drawing = "Drawing"
        static let reaction = "Reaction"
    }

    private let lastUserKey = "lastUserRecordName"
    private let lastReactionFetchKey = "lastReactionFetch"
    private let attemptsKey = "redeemAttempts"
    private let deviceIDKey = "dotdotDeviceID"

    // MARK: - Identity

    func accountState() async -> AccountState {
        do {
            switch try await container.accountStatus() {
            case .available:
                let id = try await container.userRecordID().recordName
                return .available(userID: id)
            case .noAccount:
                return .noAccount
            case .restricted:
                return .restricted
            default:
                return .unknown
            }
        } catch {
            return .unknown
        }
    }

    /// Returns true if the signed-in iCloud account changed since last launch.
    func detectAccountSwitch(currentUserID: String) -> Bool {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: lastUserKey)
        defaults.set(currentUserID, forKey: lastUserKey)
        return previous != nil && previous != currentUserID
    }

    /// Addressable endpoint for sharing. Profiles still belong to iCloud users,
    /// while pairings and messages can target a specific device on that account.
    func participantID(for userID: String) -> String {
        "\(userID)#\(deviceID)"
    }

    func profileUserID(from participantID: String) -> String {
        participantID.split(separator: "#", maxSplits: 1).first.map(String.init) ?? participantID
    }

    private var deviceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let generated = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        defaults.set(generated, forKey: deviceIDKey)
        return generated
    }

    // MARK: - Profile

    /// Fetch my profile, creating one if needed. `name`/`token` seed a new profile.
    func fetchMyProfile(userID: String) async throws -> Profile? {
        let recordID = CKRecord.ID(recordName: userID)
        do {
            let record = try await db.record(for: recordID)
            return profile(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil   // no profile yet → onboarding will create one
        }
    }

    @discardableResult
    func saveMyProfile(userID: String, name: String, token: IdentityToken, existing: Profile?) async throws -> Profile {
        let recordID = CKRecord.ID(recordName: userID)
        let record = (try? await db.record(for: recordID)) ?? CKRecord(recordType: RT.profile, recordID: recordID)
        record["name"] = name as CKRecordValue
        record["tokenSymbol"] = token.symbol as CKRecordValue
        record["tokenColor"] = token.colorIndex as CKRecordValue
        let saved = try await db.save(record)
        return profile(from: saved) ?? Profile(id: userID, name: name, token: token)
    }

    // MARK: - Pairing

    /// How long a pairing code stays valid (and is shown to its owner).
    static let inviteCodeValidity: TimeInterval = 6 * 60 * 60   // 6 hours

    /// Generate a fresh 6-digit code, valid (and reusable) for 6 hours.
    func generateCode(ownerID: String, ownerParticipantID: String) async throws -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        let record = CKRecord(recordType: RT.inviteCode)
        record["code"] = code as CKRecordValue
        record["ownerID"] = ownerID as CKRecordValue
        record["ownerParticipantID"] = ownerParticipantID as CKRecordValue
        record["expiresAt"] = Date().addingTimeInterval(Self.inviteCodeValidity) as CKRecordValue
        record["used"] = 0 as CKRecordValue
        try await db.save(record)
        return code
    }

    /// Redeem a typed 6-digit code. Throws a `PairingError` on every failure path.
    func redeemCode(_ code: String, myID: String, myParticipantID: String) async throws {
        try checkRateLimit()

        let predicate = NSPredicate(format: "code == %@", code)
        let query = CKQuery(recordType: RT.inviteCode, predicate: predicate)
        let records: [CKRecord]
        do {
            let (results, _) = try await db.records(matching: query, resultsLimit: 5)
            records = results.compactMap { try? $0.1.get() }
        } catch {
            throw PairingError.generic
        }

        guard let record = records.first else { throw PairingError.codeNotFound }

        let ownerID = record["ownerID"] as? String ?? ""
        let ownerParticipantID = record["ownerParticipantID"] as? String ?? ownerID
        let expiresAt = record["expiresAt"] as? Date ?? .distantPast

        if ownerParticipantID == myParticipantID { throw PairingError.ownCode }
        if ownerParticipantID == ownerID, ownerID == myID { throw PairingError.ownCode }
        if expiresAt < Date() { throw PairingError.codeExpired }

        // Codes are reusable until they expire, so a friend can share one with
        // several pals over the 6-hour window. The friendship itself is idempotent.
        try await createFriendship(myID: myParticipantID, otherID: ownerParticipantID)
    }

    /// Create the single friendship record for a pair. Idempotent: the recordName
    /// is the sorted pair, so simultaneous creates collapse to exactly one record.
    private func createFriendship(myID: String, otherID: String) async throws {
        let members = [myID, otherID].sorted()
        let name = "pair_" + members.map(recordNameComponent).joined(separator: "__")
        let recordID = CKRecord.ID(recordName: name)

        if (try? await db.record(for: recordID)) != nil {
            throw PairingError.alreadyFriends
        }

        let record = CKRecord(recordType: RT.friendship, recordID: recordID)
        record["members"] = members as CKRecordValue
        record["userA"] = members[0] as CKRecordValue
        record["userB"] = members[1] as CKRecordValue
        do {
            _ = try await db.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Lost the race — the friendship already exists. That's fine.
            throw PairingError.alreadyFriends
        }
    }

    // MARK: - Friends

    func fetchFriends(myID: String, myParticipantID: String) async throws -> [FriendInfo] {
        var friendshipsByID: [CKRecord.ID: CKRecord] = [:]
        for id in Set([myParticipantID, myID]) {
            let predicate = NSPredicate(format: "members CONTAINS %@", id)
            let query = CKQuery(recordType: RT.friendship, predicate: predicate)
            let (results, _) = try await db.records(matching: query, resultsLimit: CKQueryOperation.maximumResults)
            for record in results.compactMap({ try? $0.1.get() }) {
                friendshipsByID[record.recordID] = record
            }
        }

        let otherIDs: [String] = friendshipsByID.values.compactMap { record in
            let members = (record["members"] as? [String]) ?? []
            return members.first { $0 != myParticipantID && $0 != myID }
        }

        var friends: [FriendInfo] = []
        for id in Set(otherIDs) {
            let profileID = profileUserID(from: id)
            if let record = try? await db.record(for: CKRecord.ID(recordName: profileID)),
               let profile = profile(from: record) {
                friends.append(FriendInfo(id: id, name: profile.name, token: profile.token))
            }
        }
        return friends.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Remove the friendship between me and `friendID`. There's a single shared
    /// Friendship record per pair, so deleting it unfriends BOTH of us. Best-effort.
    func removeFriend(_ friendID: String, myID: String, myParticipantID: String) async {
        // The exact record (current pairings are always keyed by participant IDs).
        let members = [myParticipantID, friendID].sorted()
        let name = "pair_" + members.map(recordNameComponent).joined(separator: "__")
        _ = try? await db.deleteRecord(withID: CKRecord.ID(recordName: name))

        // Fallback: any friendship that contains BOTH me and this friend (covers a
        // legacy record keyed by user ID). Never touch the friend's OTHER pairings.
        let mine = Set([myParticipantID, myID])
        let query = CKQuery(recordType: RT.friendship, predicate: NSPredicate(format: "members CONTAINS %@", friendID))
        if let (results, _) = try? await db.records(matching: query, resultsLimit: CKQueryOperation.maximumResults) {
            for record in results.compactMap({ try? $0.1.get() }) {
                let mem = Set((record["members"] as? [String]) ?? [])
                if !mine.isDisjoint(with: mem) {
                    _ = try? await db.deleteRecord(withID: record.recordID)
                }
            }
        }
    }

    // MARK: - Delete my data

    /// Best-effort removal of the user's own CloudKit footprint: their profile,
    /// friendships involving them, the drawings they sent, and their push
    /// subscriptions. Drawings already delivered to a friend's device live in that
    /// device's App Group and can't be reached from here.
    func deleteMyData(userID: String, participantID: String) async {
        let ids = Set([participantID, userID])

        // Friendships involving me.
        for id in ids {
            let query = CKQuery(recordType: RT.friendship, predicate: NSPredicate(format: "members CONTAINS %@", id))
            if let (results, _) = try? await db.records(matching: query, resultsLimit: CKQueryOperation.maximumResults) {
                for recordID in results.map(\.0) { _ = try? await db.deleteRecord(withID: recordID) }
            }
        }

        // Drawings I sent.
        for id in ids {
            let query = CKQuery(recordType: RT.drawing, predicate: NSPredicate(format: "senderID == %@", id))
            if let (results, _) = try? await db.records(matching: query, resultsLimit: CKQueryOperation.maximumResults) {
                for recordID in results.map(\.0) { _ = try? await db.deleteRecord(withID: recordID) }
            }
        }

        // Reactions I made, and reactions others made to my (now deleted) drawings.
        for id in ids {
            for predicate in [NSPredicate(format: "reactorID == %@", id),
                              NSPredicate(format: "recipientID == %@", id)] {
                let query = CKQuery(recordType: RT.reaction, predicate: predicate)
                if let (results, _) = try? await db.records(matching: query, resultsLimit: CKQueryOperation.maximumResults) {
                    for recordID in results.map(\.0) { _ = try? await db.deleteRecord(withID: recordID) }
                }
            }
        }

        // My profile.
        _ = try? await db.deleteRecord(withID: CKRecord.ID(recordName: userID))

        // My push subscriptions, both generations (so this device stops receiving).
        for id in ids {
            let component = subscriptionIDComponent(id)
            for subscriptionID in ["drawings-to-\(component)", "drawings-to-\(component)-v2",
                                   "friendships-of-\(component)",
                                   "reactions-to-\(component)", "reactions-to-\(component)-v2"] {
                _ = try? await db.deleteSubscription(withID: subscriptionID)
            }
        }
    }

    // MARK: - Sending

    /// Write one Drawing record per recipient (dots inline, photo as a CKAsset).
    /// Returns the recipient IDs that failed so the caller can re-queue them.
    /// Retries transient errors briefly.
    /// What became of one send attempt: which recipients still need the record,
    /// the underlying error (so it can finally be SEEN in the debug panel), and
    /// whether retrying later can help. Swallowing errors here is what let the
    /// outbox rot silently.
    // nonisolated: plain data, consumed by the nonisolated retry policy
    // (AppModel.flushOutcome) and by tests.
    nonisolated struct SendResult {
        var failedRecipientIDs: [String] = []
        var lastError: Error?
        /// True when a retry can't fix it (bad record, quota, permissions) — the
        /// caller should give up instead of burning attempts.
        var isTerminal = false

        var succeeded: Bool { failedRecipientIDs.isEmpty }
    }

    func sendMessage(kind: MessageKind, grid: Grid?, imageData: Data?,
                     to recipientIDs: [String], from profile: Profile, senderID: String,
                     messageID: String? = nil) async -> SendResult {
        // For photos, stage the (already downscaled) JPEG to a temp file once; each
        // record gets its own CKAsset pointing at it.
        var assetURL: URL?
        if kind != .dots, let imageData {   // photo + doodle both ship a JPEG asset
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("jpg")
            if (try? imageData.write(to: url)) != nil {
                assetURL = url
            } else {
                return SendResult(failedRecipientIDs: recipientIDs,
                                  lastError: CocoaError(.fileWriteUnknown), isTerminal: true)
            }
        }
        defer { if let assetURL { try? FileManager.default.removeItem(at: assetURL) } }

        let gridData = (kind == .dots) ? (grid.flatMap { try? JSONEncoder().encode($0) }) : nil
        if kind == .dots && gridData == nil {
            return SendResult(failedRecipientIDs: recipientIDs,
                              lastError: CocoaError(.coderInvalidValue), isTerminal: true)
        }

        // ONE batch operation for every recipient (a photo to three friends was
        // three sequential JPEG uploads before — the asset uploads once per op).
        // withBackoff re-runs the batch for whichever recipients are still owed,
        // honoring the server's retry-after.
        func record(for recipientID: String) -> CKRecord {
            let record = CKRecord(recordType: RT.drawing)
            record["recipientID"] = recipientID as CKRecordValue
            record["senderID"] = senderID as CKRecordValue
            record["senderName"] = profile.name as CKRecordValue
            record["tokenSymbol"] = profile.token.symbol as CKRecordValue
            record["tokenColor"] = profile.token.colorIndex as CKRecordValue
            record["sentAt"] = Date() as CKRecordValue
            record["kind"] = kind.rawValue as CKRecordValue
            // Stable cross-device ID reactions point back at (needs no index —
            // it just rides the record). Same ID on every recipient's copy.
            if let messageID { record["messageID"] = messageID as CKRecordValue }
            if let gridData { record["gridData"] = gridData as CKRecordValue }
            if let assetURL { record["imageAsset"] = CKAsset(fileURL: assetURL) }
            return record
        }

        var pending = recipientIDs        // still owed a record
        var terminal: [String] = []       // failed in a way retrying can't fix
        var lastError: Error?

        let backoffError = await withBackoff(maxAttempts: 3) {
            let outcome = await self.saveDrawingBatch(pending.map { ($0, record(for: $0)) })
            lastError = outcome.lastError ?? lastError
            terminal.append(contentsOf: outcome.terminal)
            pending = outcome.retryable
            if !pending.isEmpty {
                // Signal withBackoff to re-run the batch for the stragglers.
                throw outcome.lastError ?? CKError(.networkFailure)
            }
        }
        _ = backoffError   // already folded into lastError above

        var result = SendResult()
        result.failedRecipientIDs = pending + terminal
        result.lastError = lastError
        // Retrying later only helps if at least one failure was transient.
        result.isTerminal = pending.isEmpty && !terminal.isEmpty
        return result
    }

    /// The per-batch outcome: who saved, who's worth retrying, who is a lost cause.
    private struct BatchOutcome {
        var retryable: [String] = []
        var terminal: [String] = []
        var lastError: Error?
    }

    /// Save all recipients' records in one non-atomic CKModifyRecordsOperation,
    /// mapping per-record results back to per-recipient outcomes.
    private func saveDrawingBatch(_ entries: [(recipientID: String, record: CKRecord)]) async -> BatchOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<BatchOutcome, Never>) in
            let recipientByRecordID = Dictionary(uniqueKeysWithValues: entries.map { ($0.record.recordID, $0.recipientID) })
            nonisolated(unsafe) var outcome = BatchOutcome()
            let operation = CKModifyRecordsOperation(recordsToSave: entries.map(\.record))
            operation.isAtomic = false                       // deliver to whoever we can
            operation.qualityOfService = .userInitiated      // the user just tapped send
            operation.perRecordSaveBlock = { recordID, result in
                guard case .failure(let error) = result,
                      let recipientID = recipientByRecordID[recordID] else { return }
                outcome.lastError = error
                if let ckError = error as? CKError, !ckError.isRetryable {
                    outcome.terminal.append(recipientID)
                } else {
                    outcome.retryable.append(recipientID)
                }
            }
            operation.modifyRecordsResultBlock = { result in
                if case .failure(let error) = result {
                    // Whole-op failure (e.g. no network): everyone unresolved shares it.
                    outcome.lastError = error
                    let resolved = Set(outcome.retryable + outcome.terminal)
                    let unresolved = entries.map(\.recipientID).filter { !resolved.contains($0) }
                    if let ckError = error as? CKError, !ckError.isRetryable {
                        outcome.terminal.append(contentsOf: unresolved)
                    } else {
                        outcome.retryable.append(contentsOf: unresolved)
                    }
                }
                continuation.resume(returning: outcome)
            }
            db.add(operation)
        }
    }

    // MARK: - Receiving

    /// Fetch drawings addressed to me since the last fetch, store each into the
    /// App Group (per sender + latest), and advance the high-water mark. Returns
    /// the fetched drawings so callers can surface notifications for them.
    func fetchIncoming(recipientIDs: [String]) async throws -> [DisplayDrawing] {
        let since = GridStore.shared.lastDrawingFetch ?? .distantPast

        var recordsByID: [CKRecord.ID: CKRecord] = [:]
        for id in Set(recipientIDs) {
            let predicate = NSPredicate(format: "recipientID == %@ AND sentAt > %@", id, since as NSDate)
            let query = CKQuery(recordType: RT.drawing, predicate: predicate)
            query.sortDescriptors = [NSSortDescriptor(key: "sentAt", ascending: true)]
            let (results, _) = try await db.records(matching: query, resultsLimit: CKQueryOperation.maximumResults)
            for record in results.compactMap({ try? $0.1.get() }) {
                recordsByID[record.recordID] = record
            }
        }

        var newest = since
        var fetched: [DisplayDrawing] = []
        let records = recordsByID.values.sorted {
            (($0["sentAt"] as? Date) ?? .distantPast) < (($1["sentAt"] as? Date) ?? .distantPast)
        }
        for record in records {
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
                // The asset is already a downscaled, widget-safe JPEG (the sender
                // shrank it before upload). CloudKit downloads it to a temp file.
                guard let asset = record["imageAsset"] as? CKAsset,
                      let url = asset.fileURL,
                      let data = try? Data(contentsOf: url)
                else { continue }
                drawing = kind == .doodle
                    ? .doodle(data, senderID: senderID, senderName: senderName, token: token, sentAt: sentAt, messageID: messageID)
                    : .photo(data, senderID: senderID, senderName: senderName, token: token, sentAt: sentAt, messageID: messageID)
            case .dots:
                guard let data = record["gridData"] as? Data,
                      let grid = try? JSONDecoder().decode(Grid.self, from: data)
                else { continue }
                drawing = .dots(grid, senderID: senderID, senderName: senderName, token: token, sentAt: sentAt, messageID: messageID)
            }
            GridStore.shared.saveReceived(drawing)
            newest = max(newest, sentAt)
            fetched.append(drawing)
        }
        if !fetched.isEmpty { GridStore.shared.lastDrawingFetch = newest }
        return fetched
    }

    // MARK: - Reactions

    /// One reaction per (reactor, dotdot): the record name is deterministic, so
    /// reacting again REPLACES the same record (and un-reacting deletes it).
    private func reactionRecordID(reactorID: String, messageID: String?, drawingSentAt: Date) -> CKRecord.ID {
        let key = messageID ?? "t\(Int(drawingSentAt.timeIntervalSince1970 * 1000))"
        return CKRecord.ID(recordName: "reaction-\(recordNameComponent(reactorID))-\(key)")
    }

    /// Send (or replace) my emoji reaction to a dotdot. `recipientID` is the original
    /// sender — the person who should see it on their sent feed. Returns success.
    func sendReaction(emoji: String, messageID: String?, drawingSentAt: Date,
                      to recipientID: String, from profile: Profile, reactorID: String) async -> Bool {
        let recordID = reactionRecordID(reactorID: reactorID, messageID: messageID, drawingSentAt: drawingSentAt)
        let error = await withBackoff(maxAttempts: 3) {
            // Upsert: mutate the existing record if I reacted before, else create it.
            let record = (try? await self.db.record(for: recordID)) ?? CKRecord(recordType: RT.reaction, recordID: recordID)
            record["emoji"] = emoji as CKRecordValue
            record["recipientID"] = recipientID as CKRecordValue
            record["reactorID"] = reactorID as CKRecordValue
            record["reactorName"] = profile.name as CKRecordValue
            if let messageID { record["messageID"] = messageID as CKRecordValue }
            record["drawingSentAt"] = drawingSentAt as CKRecordValue
            // Bumped on every save so replacements clear the recipient's fetch mark.
            record["sentAt"] = Date() as CKRecordValue
            _ = try await self.db.save(record)
        }
        return error == nil
    }

    /// Un-react: best-effort delete of my reaction record.
    func removeReaction(messageID: String?, drawingSentAt: Date, reactorID: String) async {
        let recordID = reactionRecordID(reactorID: reactorID, messageID: messageID, drawingSentAt: drawingSentAt)
        _ = try? await db.deleteRecord(withID: recordID)
    }

    /// One freshly fetched reaction, with enough context to notify about it.
    struct FetchedReaction {
        let info: ReactionInfo
        let messageID: String?
    }

    /// Fetch reactions to dotdots I sent since the last fetch and attach them to the
    /// sent feed. Mirrors `fetchIncoming` (high-water mark on the reaction's save
    /// time). Returns the fetched reactions so callers can surface notifications.
    func fetchReactions(recipientIDs: [String]) async throws -> [FetchedReaction] {
        let defaults = UserDefaults.standard
        let since = (defaults.object(forKey: lastReactionFetchKey) as? Date) ?? .distantPast

        var recordsByID: [CKRecord.ID: CKRecord] = [:]
        for id in Set(recipientIDs) {
            let predicate = NSPredicate(format: "recipientID == %@ AND sentAt > %@", id, since as NSDate)
            let query = CKQuery(recordType: RT.reaction, predicate: predicate)
            query.sortDescriptors = [NSSortDescriptor(key: "sentAt", ascending: true)]
            let (results, _) = try await db.records(matching: query, resultsLimit: CKQueryOperation.maximumResults)
            for record in results.compactMap({ try? $0.1.get() }) {
                recordsByID[record.recordID] = record
            }
        }

        var newest = since
        var fetched: [FetchedReaction] = []
        for record in recordsByID.values {
            guard let emoji = record["emoji"] as? String,
                  let reactorID = record["reactorID"] as? String else { continue }
            let at = (record["sentAt"] as? Date) ?? Date()
            let reaction = ReactionInfo(
                emoji: emoji,
                reactorID: reactorID,
                reactorName: record["reactorName"] as? String ?? "friend",
                at: at
            )
            let messageID = record["messageID"] as? String
            GridStore.shared.applyIncomingReaction(
                reaction,
                messageID: messageID,
                drawingSentAt: (record["drawingSentAt"] as? Date) ?? .distantPast
            )
            newest = max(newest, at)
            fetched.append(FetchedReaction(info: reaction, messageID: messageID))
        }
        if !fetched.isEmpty { defaults.set(newest, forKey: lastReactionFetchKey) }
        return fetched
    }

    // MARK: - Subscription (push)

    /// Subscribe to drawings addressed to me, new friendships involving me, AND
    /// reactions to dotdots I sent — so both parties learn in real time. Idempotent
    /// (CKModifySubscriptionsOperation updates same-ID subscriptions in place).
    ///
    /// Drawing/reaction pushes are VISIBLE when their alert toggle is on (banner
    /// rendered server-side, rewritten by the service extension, delivered even to
    /// a force-quit app) and silent when off — either way they stay
    /// content-available so a live app wakes to fetch. The sender never receives
    /// their own push: the predicates are all `recipientID == me`, and a sender's
    /// records carry the FRIEND's id there.
    func ensureSubscription(userID: String, participantID: String,
                            drawingAlertsVisible: Bool, reactionAlertsVisible: Bool) async {
        for id in Set([userID, participantID]) {
            let component = subscriptionIDComponent(id)

            let drawings = CKQuerySubscription(
                recordType: RT.drawing,
                predicate: NSPredicate(format: "recipientID == %@", id),
                subscriptionID: "drawings-to-\(component)-v2",
                options: [.firesOnRecordCreation]
            )
            drawings.notificationInfo = drawingAlertsVisible
                ? visibleInfo(localizationKey: "PUSH_DRAWING", args: ["senderName"],
                              sound: "dotdot.caf",
                              desiredKeys: ["senderName", "kind", "senderID", "sentAt", "messageID"])
                : silentInfo()

            let friendships = CKQuerySubscription(
                recordType: RT.friendship,
                predicate: NSPredicate(format: "members CONTAINS %@", id),
                subscriptionID: "friendships-of-\(component)",
                options: [.firesOnRecordCreation]
            )
            friendships.notificationInfo = silentInfo()   // connected banner stays local

            let reactions = CKQuerySubscription(
                recordType: RT.reaction,
                predicate: NSPredicate(format: "recipientID == %@", id),
                subscriptionID: "reactions-to-\(component)-v2",
                // Update too: replacing a reaction mutates the SAME record.
                options: [.firesOnRecordCreation, .firesOnRecordUpdate]
            )
            reactions.notificationInfo = reactionAlertsVisible
                ? visibleInfo(localizationKey: "PUSH_REACTION", args: ["reactorName"],
                              sound: "default",
                              desiredKeys: ["reactorName", "messageID"])
                : silentInfo()

            // Save the current generation and retire the v1 silent ones in one op.
            _ = try? await db.modifySubscriptions(
                saving: [drawings, friendships, reactions],
                deleting: ["drawings-to-\(component)", "reactions-to-\(component)"]
            )
        }
    }

    private func silentInfo() -> CKSubscription.NotificationInfo {
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        return info
    }

    private func visibleInfo(localizationKey: String, args: [String], sound: String,
                             desiredKeys: [CKRecord.FieldKey]) -> CKSubscription.NotificationInfo {
        let info = CKSubscription.NotificationInfo()
        info.alertLocalizationKey = localizationKey       // server-rendered fallback copy
        info.alertLocalizationArgs = args
        info.soundName = sound
        info.desiredKeys = desiredKeys                    // ride the payload; no fetch needed for copy
        info.shouldSendMutableContent = true              // the service extension rewrites the banner
        info.shouldSendContentAvailable = true            // a live app still wakes to fetch
        return info
    }

    // MARK: - Helpers

    private func profile(from record: CKRecord) -> Profile? {
        guard let name = record["name"] as? String else { return nil }
        let token = IdentityToken(
            symbol: record["tokenSymbol"] as? String ?? "✦",
            colorIndex: record["tokenColor"] as? Int ?? 0
        )
        return Profile(
            id: record.recordID.recordName,
            name: name,
            token: token
        )
    }

    private func recordNameComponent(_ id: String) -> String {
        Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func subscriptionIDComponent(_ id: String) -> String {
        id.replacingOccurrences(of: "#", with: "-")
    }

    private func checkRateLimit() throws {
        let defaults = UserDefaults.standard
        let now = Date()
        var stamps = (defaults.array(forKey: attemptsKey) as? [Date]) ?? []
        stamps = stamps.filter { now.timeIntervalSince($0) < 60 }
        guard stamps.count < 5 else { throw PairingError.rateLimited }
        stamps.append(now)
        defaults.set(stamps, forKey: attemptsKey)
    }

    /// Runs `work` with short in-place backoff. Returns nil on success, or the
    /// LAST error — callers surface it instead of letting failures vanish.
    private func withBackoff(maxAttempts: Int, _ work: @escaping () async throws -> Void) async -> Error? {
        var delay: UInt64 = 400_000_000   // 0.4s
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try await work()
                return nil
            } catch let error as CKError where error.isRetryable && attempt < maxAttempts {
                lastError = error
                let suggested = error.retryAfterSeconds.map { UInt64($0 * 1_000_000_000) } ?? delay
                try? await Task.sleep(nanoseconds: suggested)
                delay *= 2
            } catch {
                return error
            }
        }
        return lastError
    }
}

extension CKError {
    var isRetryable: Bool {
        switch code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            return true
        default:
            return false
        }
    }
    var retryAfterSeconds: Double? {
        userInfo[CKErrorRetryAfterKey] as? Double
    }
}
