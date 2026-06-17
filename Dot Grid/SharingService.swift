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
//    • Profile     recordName=<userID>   fields: name, tokenSymbol, tokenColor,
//                  inviteToken (QUERYABLE)
//    • Friendship  recordName="pair_<a>__<b>"  fields: members [String] (QUERYABLE)
//    • InviteCode  fields: code (QUERYABLE), ownerID, expiresAt, used
//    • Drawing     fields: recipientID (QUERYABLE), sentAt (SORTABLE/QUERYABLE),
//                  senderID, senderName, tokenSymbol, tokenColor, gridData
//

import CloudKit
import Foundation

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
    }

    private let lastUserKey = "lastUserRecordName"
    private let lastFetchKey = "lastDrawingFetch"
    private let attemptsKey = "redeemAttempts"

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
        let inviteToken = existing?.inviteToken ?? (record["inviteToken"] as? String) ?? Self.randomToken(length: 22)
        record["inviteToken"] = inviteToken as CKRecordValue
        let saved = try await db.save(record)
        return profile(from: saved) ?? Profile(id: userID, name: name, token: token, inviteToken: inviteToken)
    }

    // MARK: - Pairing

    /// Generate a fresh single-use 6-digit code, valid for 10 minutes.
    func generateCode(ownerID: String) async throws -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        let record = CKRecord(recordType: RT.inviteCode)
        record["code"] = code as CKRecordValue
        record["ownerID"] = ownerID as CKRecordValue
        record["expiresAt"] = Date().addingTimeInterval(600) as CKRecordValue
        record["used"] = 0 as CKRecordValue
        try await db.save(record)
        return code
    }

    /// The shareable invite link for this user.
    func inviteLink(for profile: Profile) -> URL {
        URL(string: "https://dotdot.app/i/\(profile.inviteToken)")!
    }

    /// Redeem a typed 6-digit code. Throws a `PairingError` on every failure path.
    func redeemCode(_ code: String, myID: String) async throws {
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
        let expiresAt = record["expiresAt"] as? Date ?? .distantPast
        let used = (record["used"] as? Int) ?? 0

        if ownerID == myID { throw PairingError.ownCode }
        if used != 0 { throw PairingError.codeUsed }
        if expiresAt < Date() { throw PairingError.codeExpired }

        try await createFriendship(myID: myID, otherID: ownerID)

        // Burn the code (best-effort; friendship already exists idempotently).
        record["used"] = 1 as CKRecordValue
        record["usedBy"] = myID as CKRecordValue
        _ = try? await db.save(record)
    }

    /// Redeem an invite link's token.
    func redeemInvite(token: String, myID: String) async throws {
        let predicate = NSPredicate(format: "inviteToken == %@", token)
        let query = CKQuery(recordType: RT.profile, predicate: predicate)
        let owner: CKRecord?
        do {
            let (results, _) = try await db.records(matching: query, resultsLimit: 2)
            owner = results.compactMap { try? $0.1.get() }.first
        } catch {
            throw PairingError.generic
        }
        guard let owner else { throw PairingError.codeNotFound }
        let ownerID = owner.recordID.recordName
        if ownerID == myID { throw PairingError.ownCode }
        try await createFriendship(myID: myID, otherID: ownerID)
    }

    /// Create the single friendship record for a pair. Idempotent: the recordName
    /// is the sorted pair, so simultaneous creates collapse to exactly one record.
    private func createFriendship(myID: String, otherID: String) async throws {
        let name = "pair_" + [myID, otherID].sorted().joined(separator: "__")
        let recordID = CKRecord.ID(recordName: name)

        if (try? await db.record(for: recordID)) != nil {
            throw PairingError.alreadyFriends
        }

        let record = CKRecord(recordType: RT.friendship, recordID: recordID)
        record["members"] = [myID, otherID].sorted() as CKRecordValue
        record["userA"] = [myID, otherID].sorted()[0] as CKRecordValue
        record["userB"] = [myID, otherID].sorted()[1] as CKRecordValue
        do {
            _ = try await db.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Lost the race — the friendship already exists. That's fine.
            throw PairingError.alreadyFriends
        }
    }

    // MARK: - Friends

    func fetchFriends(myID: String) async throws -> [FriendInfo] {
        let predicate = NSPredicate(format: "members CONTAINS %@", myID)
        let query = CKQuery(recordType: RT.friendship, predicate: predicate)
        let (results, _) = try await db.records(matching: query, resultsLimit: CKQueryOperation.maximumResults)
        let friendships = results.compactMap { try? $0.1.get() }

        let otherIDs: [String] = friendships.compactMap { record in
            let members = (record["members"] as? [String]) ?? []
            return members.first { $0 != myID }
        }

        var friends: [FriendInfo] = []
        for id in Set(otherIDs) {
            if let record = try? await db.record(for: CKRecord.ID(recordName: id)),
               let profile = profile(from: record) {
                friends.append(FriendInfo(id: profile.id, name: profile.name, token: profile.token))
            }
        }
        return friends.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Sending

    /// Write one Drawing record per recipient. Returns the recipient IDs that
    /// failed so the caller can re-queue them. Retries transient errors briefly.
    func sendDrawing(grid: Grid, to recipientIDs: [String], from profile: Profile) async -> [String] {
        guard let gridData = try? JSONEncoder().encode(grid) else { return recipientIDs }
        var failed: [String] = []
        for recipientID in recipientIDs {
            let ok = await withBackoff(maxAttempts: 3) {
                let record = CKRecord(recordType: RT.drawing)
                record["recipientID"] = recipientID as CKRecordValue
                record["senderID"] = profile.id as CKRecordValue
                record["senderName"] = profile.name as CKRecordValue
                record["tokenSymbol"] = profile.token.symbol as CKRecordValue
                record["tokenColor"] = profile.token.colorIndex as CKRecordValue
                record["sentAt"] = Date() as CKRecordValue
                record["gridData"] = gridData as CKRecordValue
                _ = try await self.db.save(record)
            }
            if !ok { failed.append(recipientID) }
        }
        return failed
    }

    // MARK: - Receiving

    /// Fetch drawings addressed to me since the last fetch, store each into the
    /// App Group (per sender + latest), and advance the high-water mark.
    @discardableResult
    func fetchIncoming(myID: String) async -> Int {
        let defaults = UserDefaults.standard
        let since = (defaults.object(forKey: lastFetchKey) as? Date) ?? .distantPast

        let predicate = NSPredicate(format: "recipientID == %@ AND sentAt > %@", myID, since as NSDate)
        let query = CKQuery(recordType: RT.drawing, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "sentAt", ascending: true)]

        guard let (results, _) = try? await db.records(matching: query, resultsLimit: CKQueryOperation.maximumResults) else {
            return 0
        }
        let records = results.compactMap { try? $0.1.get() }

        var newest = since
        var count = 0
        for record in records {
            guard
                let data = record["gridData"] as? Data,
                let grid = try? JSONDecoder().decode(Grid.self, from: data)
            else { continue }
            let sentAt = (record["sentAt"] as? Date) ?? Date()
            let drawing = DisplayDrawing(
                grid: grid,
                senderID: record["senderID"] as? String ?? "",
                senderName: record["senderName"] as? String ?? "Friend",
                token: IdentityToken(
                    symbol: record["tokenSymbol"] as? String ?? "✦",
                    colorIndex: record["tokenColor"] as? Int ?? 0
                ),
                sentAt: sentAt
            )
            GridStore.shared.saveReceived(drawing)
            newest = max(newest, sentAt)
            count += 1
        }
        if count > 0 { defaults.set(newest, forKey: lastFetchKey) }
        return count
    }

    // MARK: - Subscription (push)

    /// Subscribe to drawings addressed to me. Idempotent per user.
    func ensureSubscription(myID: String) async {
        let id = "drawings-to-\(myID)"
        let predicate = NSPredicate(format: "recipientID == %@", myID)
        let subscription = CKQuerySubscription(
            recordType: RT.drawing,
            predicate: predicate,
            subscriptionID: id,
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent push
        subscription.notificationInfo = info
        _ = try? await db.save(subscription)
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
            token: token,
            inviteToken: record["inviteToken"] as? String ?? ""
        )
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

    private func withBackoff(maxAttempts: Int, _ work: @escaping () async throws -> Void) async -> Bool {
        var delay: UInt64 = 400_000_000   // 0.4s
        for attempt in 1...maxAttempts {
            do {
                try await work()
                return true
            } catch let error as CKError where error.isRetryable && attempt < maxAttempts {
                let suggested = error.retryAfterSeconds.map { UInt64($0 * 1_000_000_000) } ?? delay
                try? await Task.sleep(nanoseconds: suggested)
                delay *= 2
            } catch {
                return false
            }
        }
        return false
    }

    static func randomToken(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}

private extension CKError {
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
