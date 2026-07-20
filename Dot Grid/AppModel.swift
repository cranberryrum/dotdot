//
//  AppModel.swift
//  Dot Grid
//
//  The orchestration brain between the composer UI, the local GridStore/App Group
//  pipe, and CloudKit. Owns iCloud state, identity, friends, and the local-first
//  send queue. The widget never sees this — it only reads GridStore.
//

import BackgroundTasks
import CloudKit
import Foundation
import Network
import SwiftUI
import WidgetKit

@Observable
@MainActor
final class AppModel {
    // Routing
    enum Phase: Equatable {
        case loading
        case onboarding
        case ready
        case iCloudUnavailable   // not signed in / restricted — local-only drawing
    }

    /// Shared instance so the push delegate (outside the SwiftUI tree) can reach it.
    static let shared = AppModel()

    private(set) var phase: Phase = .loading
    private(set) var account: AccountState = .unknown
    private(set) var profile: Profile?
    private(set) var friends: [FriendInfo] = []
    private(set) var outbox: [QueuedSend] = []
    private(set) var isOnline = true

    /// The user's current pairing code, persisted per-device and shown until it
    /// expires (6 hours). Reused across app opens so it's always ready to share.
    private(set) var inviteCode: String?
    private(set) var inviteCodeExpiresAt: Date?

    /// True when a friend has sent a dotdot the user hasn't opened the inbox to see.
    /// Drives the wordmark shimmer. Cleared by `markInboxSeen()`.
    private(set) var inboxHasUnread = false

    /// Bumped on a warm app-open or a live arrival while unread, so the wordmark can
    /// replay its shimmer for that event (the cold-launch case is driven by unread).
    private(set) var inboxShimmerNonce = 0

    /// Monotonic in-process signal that an App Group projection changed. Views
    /// keep their lightweight local arrays, but refresh them whenever delivery,
    /// reaction, or send-status work finishes after the sheet has already opened.
    private(set) var deliveryRevision = 0

    /// Where a tapped notification wants to land (a specific drawing or friend).
    /// ComposerView opens the right sheet; the sheet consumes the detail and
    /// clears it — never a generic home-screen dump.
    var pendingRoute: NotificationRoute?

    /// The notification-permission flow (soft ask, live OS status, feed-nudge state).
    /// Sending never depends on it.
    @ObservationIgnored let notifications = NotificationGate()

    /// A transient top toast. Every transient message in the app goes through
    /// `showToast` so they're all consistent: top, swipe-to-dismiss, same motion.
    struct Toast: Identifiable, Equatable {
        let id: UUID
        var message: String
        var icon: String?           // SF Symbol
        var actionTitle: String?    // e.g. "undo"
        var duration: TimeInterval
        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    private(set) var toast: Toast?
    private var toastAction: (() -> Void)?

    /// Show a toast. `action`/`actionTitle` add a trailing button (e.g. undo). The
    /// ToastView owns timing + dismissal animation; this just sets the state.
    func showToast(_ message: String, icon: String? = nil, actionTitle: String? = nil,
                   duration: TimeInterval = 3, action: (() -> Void)? = nil) {
        toastAction = actionTitle == nil ? nil : action
        toast = Toast(id: UUID(), message: message, icon: icon,
                      actionTitle: actionTitle, duration: duration)
    }

    /// Run the toast's action button (the view handles its own dismissal after).
    func runToastAction() { toastAction?() }

    /// Clear the toast once it has animated off-screen.
    func dismissToast() {
        toast = nil
        toastAction = nil
    }

    /// Last non-fatal CloudKit error, surfaced in the debug panel.
    private(set) var lastError: String?

    // Debug-panel accessors
    var userID: String? {
        if case let .available(id) = account { id } else { nil }
    }
    var accountDescription: String {
        switch account {
        case .available: "Signed in"
        case .noAccount: "Not signed into iCloud"
        case .restricted: "Restricted"
        case .unknown: "Unknown / unavailable"
        }
    }

    /// Re-run the full sync; used by the debug panel's Refresh button.
    func debugRefresh() async {
        lastError = nil
        await bootstrap()
    }

    private(set) var lastRecipientIDs: [String]

    private let service = SharingService.shared
    private let monitor = NWPathMonitor()
    private var didStart = false

    init() {
        profile = GridStore.shared.loadProfile()
        // Local-first friends: hydrate from the App Group roster (kept fresh by every
        // refreshFriends) so the recipient strip renders IMMEDIATELY on launch — an
        // instant send goes to your friends, not a local-only echo. Without this,
        // friends stayed empty until the CloudKit query returned, and a quick send
        // fell through to "only you". CloudKit reconciles moments later (bootstrap /
        // onForeground); an account switch clears the roster before it's ever wrong.
        friends = GridStore.shared.roster()
        outbox = GridStore.shared.loadOutbox()
        lastRecipientIDs = UserDefaults.standard.stringArray(forKey: "lastRecipients") ?? []
        inboxHasUnread = computeInboxUnread()   // from cache, so the cold launch knows immediately
    }

    // MARK: - Lifecycle

    func start() {
        guard !didStart else { return }
        didStart = true
        startNetworkMonitor()
        // Flipping the drawings/reactions alert toggles re-shapes the CloudKit
        // subscriptions (visible ↔ silent) — the banner is server-side now, so the
        // toggle must reach the server to actually silence it.
        notifications.onAlertRoutingChanged = { [weak self] in
            guard let self, case let .available(userID) = self.account else { return }
            Task { await self.refreshPushSubscriptions(userID: userID) }
        }
        Task { await bootstrap() }
    }

    private static let subscriptionShapeKey = "pushSubscriptionShape"
    private static let subscriptionVerifiedAtKey = "pushSubscriptionVerifiedAt"
    private static let subscriptionVerificationTTL: TimeInterval = 24 * 60 * 60

    /// (Re)assert the push subscriptions with the current per-type toggle shape:
    /// visible + mutable when the toggle is on, silent (data-only) when off.
    /// Skipped when the last recent SUCCESSFUL ensure had this exact shape. The
    /// 24-hour verification TTL avoids six redundant saves on every foreground,
    /// while still repairing a subscription later removed or invalidated server-side.
    /// Bump the shape tag when the subscription layout changes.
    private func refreshPushSubscriptions(userID: String) async {
        let shape = "v3|\(userID)|\(participantID(for: userID))"
            + "|d:\(notifications.drawingAlerts)|r:\(notifications.reactionAlerts)"
        let defaults = UserDefaults.standard
        let lastVerified = defaults.object(forKey: Self.subscriptionVerifiedAtKey) as? Date
        let recentlyVerified = lastVerified.map {
            Date().timeIntervalSince($0) < Self.subscriptionVerificationTTL
        } ?? false
        guard defaults.string(forKey: Self.subscriptionShapeKey) != shape || !recentlyVerified else { return }
        let saved = await service.ensureSubscription(
            userID: userID,
            participantID: participantID(for: userID),
            drawingAlertsVisible: notifications.drawingAlerts,
            reactionAlertsVisible: notifications.reactionAlerts
        )
        if saved {
            defaults.set(shape, forKey: Self.subscriptionShapeKey)
            defaults.set(Date(), forKey: Self.subscriptionVerifiedAtKey)
        }
    }

    /// Full sync: account check, account-switch handling, identity, friends,
    /// subscription, incoming drawings, and outbox flush.
    func bootstrap() async {
        await notifications.refresh()   // live notification status, never cached
        phase = profile == nil ? .loading : .ready
        account = await service.accountState()

        guard case let .available(userID) = account else {
            phase = .iCloudUnavailable
            return
        }

        if service.detectAccountSwitch(currentUserID: userID) {
            // A different iCloud account → start fresh. Friends are tied to identity.
            GridStore.shared.clearSharedState()
            profile = nil
            friends = []
            lastRecipientIDs = []
            outbox = []
            UserDefaults.standard.removeObject(forKey: "lastRecipients")
            UserDefaults.standard.removeObject(forKey: "lastDrawingFetch")
            UserDefaults.standard.removeObject(forKey: "lastDrawingServerFetch.v2")
            UserDefaults.standard.removeObject(forKey: "lastReactionFetch")
            UserDefaults.standard.removeObject(forKey: "lastReactionServerFetch.v2")
            UserDefaults.standard.removeObject(forKey: Self.reactionOutboxKey)
            UserDefaults.standard.removeObject(forKey: Self.inboxSeenKey)
            UserDefaults.standard.removeObject(forKey: Self.subscriptionShapeKey)
            UserDefaults.standard.removeObject(forKey: Self.subscriptionVerifiedAtKey)
            inboxHasUnread = false
            clearInviteCode()
            WidgetCenter.shared.reloadAllTimelines()
        }

        // Identity / profile
        do {
            if let remote = try await service.fetchMyProfile(userID: userID) {
                profile = remote
                GridStore.shared.saveProfile(remote)
            }
        } catch {
            lastError = "Profile fetch: \(error.localizedDescription)"
        }

        phase = profile == nil ? .onboarding : .ready

        guard profile != nil else { return }   // finish onboarding first

        await refreshPushSubscriptions(userID: userID)
        await PushNotifier.notifyNewFriends(await refreshFriends())   // bookkeeping; banners gate off
        await pullIncoming()
        await flushOutbox()
        WidgetCenter.shared.reloadAllTimelines()   // cold-launch catch-up; see onForeground
    }

    /// Lighter refresh when the app returns to the foreground.
    func onForeground() async {
        await notifications.refresh()   // user may have changed it in iOS Settings while away
        account = await service.accountState()
        if case let .available(userID) = account, profile != nil {
            if phase == .iCloudUnavailable { await bootstrap(); return }
            // Re-assert when the shape changed or its successful verification is
            // older than the TTL. Failed attempts are never cached.
            await refreshPushSubscriptions(userID: userID)
            // Pick up friends added by the other party (bookkeeping; banners gate off
            // while foregrounded — the friends list itself is the cue).
            await PushNotifier.notifyNewFriends(await refreshFriends())
            await pullIncoming()
            await flushOutbox()
            if inboxHasUnread { inboxShimmerNonce &+= 1 }   // warm open with unread → shimmer
            // ALWAYS reload here, not just when this pull fetched something: a push may
            // have fetched + saved while backgrounded (advancing the high-water mark, so
            // the pull above finds nothing) with ITS reload budget-throttled by iOS —
            // leaving the widget stale while the inbox has the message. Foreground is
            // the one moment reloads are effectively free and applied promptly.
            WidgetCenter.shared.reloadAllTimelines()
        } else if case .available = account, profile == nil {
            await bootstrap()
        } else {
            phase = .iCloudUnavailable
        }
    }

    var isSignedIn: Bool {
        if case .available = account { true } else { false }
    }

    /// Called from the push handler — also works on a cold background launch
    /// where `account` hasn't been resolved yet. Returns whether anything new was
    /// fetched, so the push completion can report .newData/.noData honestly (iOS
    /// uses that record to decide how eagerly to keep waking us).
    ///
    /// Ordered by what the push is FOR: the drawing lands and the widget reloads
    /// before anything else spends the ~30s background budget. The friends
    /// refresh (a whole query + profile fetch) only runs for friendship pushes —
    /// a drawing needs no roster; its sender's name and token ride the record.
    @discardableResult
    func handlePush(subscriptionID: String? = nil, recordID: CKRecord.ID? = nil) async -> Bool {
        if case .available = account {} else { account = await service.accountState() }
        guard case let .available(userID) = account else { return false }
        let recipientIDs = incomingRecipientIDs(for: userID)
        let isDrawingPush = subscriptionID?.hasPrefix("drawings-to-") ?? false
        let isReactionPush = subscriptionID?.hasPrefix("reactions-to-") ?? false
        let isFriendshipPush = subscriptionID?.hasPrefix("friendships-of-") ?? false
        let unknownOrigin = subscriptionID == nil
        var changed = false

        // Fast path first: a query push names the exact record. This is independent
        // of the eventually-consistent public query index and makes notification
        // taps land their content before the inbox sheet reads the store.
        if (isDrawingPush || unknownOrigin), let recordID {
            do {
                let exact = try await service.fetchIncoming(
                    recordID: recordID, recipientIDs: recipientIDs)
                changed = landIncoming(exact) || changed
                // Even if the notification extension already inserted it, wake any
                // currently open inbox so it re-reads the shared store.
                deliveryRevision &+= 1
            } catch {
                lastError = "Push drawing fetch: \(error.localizedDescription)"
            }
        } else if (isReactionPush || unknownOrigin), let recordID {
            do {
                if try await service.fetchReaction(recordID: recordID, recipientIDs: recipientIDs) != nil {
                    deliveryRevision &+= 1
                    changed = true
                }
            } catch {
                lastError = "Push reaction fetch: \(error.localizedDescription)"
            }
        }

        // Pushes are coalescible hints, so reconcile the matching stream after the
        // exact record has landed. Unknown/legacy pushes sweep all streams.
        if isDrawingPush || unknownOrigin {
            do {
                changed = landIncoming(try await service.fetchIncoming(recipientIDs: recipientIDs)) || changed
            } catch {
                lastError = "Incoming fetch: \(error.localizedDescription)"
            }
        }
        if isReactionPush || unknownOrigin {
            if let reactions = try? await service.fetchReactions(recipientIDs: recipientIDs),
               !reactions.isEmpty {
                deliveryRevision &+= 1
                changed = true
            }
        }

        let newFriends = (isFriendshipPush || unknownOrigin) ? await refreshFriends() : []
        // Drawing/reaction banners are SERVER pushes now (rewritten by the service
        // extension); locally we keep the connected banner + first-sender records.
        await PushNotifier.notifyNewFriends(newFriends)
        return changed || !newFriends.isEmpty
    }

    // MARK: - Onboarding

    /// Step 1 of onboarding: create the profile. Stays on the onboarding flow so
    /// step 2 (add a friend) can run before landing in the composer.
    func createProfile(name: String, token: IdentityToken) async throws {
        guard case let .available(userID) = account else { throw PairingError.notSignedIn }
        let saved = try await service.saveMyProfile(userID: userID, name: name, token: token, existing: profile)
        profile = saved
        GridStore.shared.saveProfile(saved)
        await refreshPushSubscriptions(userID: userID)
        await refreshFriends()
        await pullIncoming()
    }

    /// Update the profile from the Settings screen (reuses the same save path).
    func updateProfile(name: String, token: IdentityToken) async throws {
        guard case .available = account else { throw PairingError.notSignedIn }
        try await createProfile(name: name, token: token)
    }

    /// Step 2 done (added a friend or skipped) → land in the composer.
    func markReady() { phase = .ready }

    // MARK: - Delete my data

    /// Remove the user's CloudKit footprint (profile, friendships, sent drawings,
    /// subscriptions), wipe local state to a fresh install, and return to onboarding.
    /// Drawings already delivered to a friend's device may still exist there.
    func deleteAllMyData() async {
        guard case let .available(userID) = account else { return }
        await service.deleteMyData(userID: userID, participantID: participantID(for: userID))

        GridStore.shared.clearSharedState()
        let defaults = UserDefaults.standard
        // subscriptionShapeKey too: the server-side subscriptions were just
        // deleted, so the "already ensured" cache would leave this device deaf.
        for key in ["lastUserRecordName", "lastDrawingFetch", "lastDrawingServerFetch.v2",
                    "lastReactionFetch", "lastReactionServerFetch.v2", "redeemAttempts", "lastRecipients",
                    "dotdotDeviceID", Self.inboxSeenKey, Self.subscriptionShapeKey,
                    Self.subscriptionVerifiedAtKey] {
            defaults.removeObject(forKey: key)
        }
        clearInviteCode()
        profile = nil
        friends = []
        outbox = []
        lastRecipientIDs = []
        inboxHasUnread = false
        lastError = nil
        WidgetCenter.shared.reloadAllTimelines()
        phase = .onboarding
    }

    // MARK: - Pairing

    private static let codeKey = "inviteCode"
    private static let codeExpiryKey = "inviteCodeExpiresAt"
    private static let codeOwnerKey = "inviteCodeOwner"

    /// Show the saved code if it's still valid for this device, otherwise mint a
    /// fresh one. Called when the friends/settings screens appear.
    func loadOrMintCode() async {
        guard case let .available(userID) = account else { return }
        let owner = participantID(for: userID)
        let d = UserDefaults.standard
        if let code = d.string(forKey: Self.codeKey),
           let exp = d.object(forKey: Self.codeExpiryKey) as? Date,
           d.string(forKey: Self.codeOwnerKey) == owner,
           exp > Date() {
            inviteCode = code
            inviteCodeExpiresAt = exp
            return
        }
        await mintCode()
    }

    /// Force a brand-new code (the user tapped "new code"), persisted for 6 hours.
    @discardableResult
    func mintCode() async -> Bool {
        guard case let .available(userID) = account else { return false }
        let owner = participantID(for: userID)
        do {
            let code = try await service.generateCode(ownerID: userID, ownerParticipantID: owner)
            let exp = Date().addingTimeInterval(SharingService.inviteCodeValidity)
            inviteCode = code
            inviteCodeExpiresAt = exp
            let d = UserDefaults.standard
            d.set(code, forKey: Self.codeKey)
            d.set(exp, forKey: Self.codeExpiryKey)
            d.set(owner, forKey: Self.codeOwnerKey)
            return true
        } catch {
            return false
        }
    }

    private func clearInviteCode() {
        inviteCode = nil
        inviteCodeExpiresAt = nil
        let d = UserDefaults.standard
        [Self.codeKey, Self.codeExpiryKey, Self.codeOwnerKey].forEach { d.removeObject(forKey: $0) }
    }

    /// The message shared via the share sheet — a little pitch + the code.
    static func inviteMessage(code: String) -> String {
        """
        add me on dotdot ✦ we send tiny dot-grid doodles & photos straight to each other's home-screen widget.

        open the app → add a friend → enter my code: \(code) (good for 6 hours)
        """
    }

    func addFriend(byCode code: String) async throws {
        guard case let .available(userID) = account else { throw PairingError.notSignedIn }
        try await service.redeemCode(code, myID: userID, myParticipantID: participantID(for: userID))
        // I typed the code — I'm the actor. Whatever this refresh discovers is
        // self-initiated, so the "connected with you" push never echoes back to me.
        let added = await refreshFriends()
        added.forEach { PushNotifier.markFriendshipSelfInitiated($0.id) }
        // First successful pairing makes the loop real — prime once if that's first.
        notifications.noteLoopBecameReal()
    }

    /// Public refresh for the friends screen (pull the latest roster from CloudKit).
    func reloadFriends() async { await PushNotifier.notifyNewFriends(await refreshFriends()) }

    /// Remove a friend on both sides (deletes the shared Friendship record), and
    /// update the local roster immediately.
    func removeFriend(_ friend: FriendInfo) async {
        guard case let .available(userID) = account else { return }
        await service.removeFriend(friend.id, myID: userID, myParticipantID: participantID(for: userID))
        friends.removeAll { $0.id == friend.id }
        GridStore.shared.saveRoster(friends)
    }

    /// Refresh the roster from CloudKit. Returns friends that are NEW relative to
    /// what this device already knew — the "someone connected with you" signal.
    @discardableResult
    private func refreshFriends() async -> [FriendInfo] {
        guard case let .available(userID) = account else { return [] }
        do {
            let list = try await service.fetchFriends(myID: userID, myParticipantID: participantID(for: userID))
            let known = Set(friends.map(\.id))
            friends = list
            GridStore.shared.saveRoster(list)
            seedRecipientSelectionIfNeeded()   // ready before the inline strip appears
            if lastError?.hasPrefix("Friends fetch:") == true { lastError = nil }
            return list.filter { !known.contains($0.id) }
        } catch {
            lastError = "Friends fetch: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: - Inline recipient selection (the strip above Send)

    /// Who the next send goes to, picked inline above the send button and shared
    /// across all three modes. Seeded once from the last people you sent to.
    var selectedRecipientIDs: Set<String> = []
    private var didSeedRecipients = false

    /// Friends exist to pick from — the inline strip shows only then. With no
    /// friends, sending falls back to a local-only echo (unchanged).
    var canPickRecipients: Bool { isSignedIn && !friends.isEmpty }

    /// The selection narrowed to people who are still friends (safe to send to).
    var resolvedRecipientIDs: [String] {
        let valid = Set(friends.map(\.id))
        return Array(selectedRecipientIDs.intersection(valid))
    }

    /// Every current friend is selected — drives the "everyone" chip's state.
    var isAllRecipientsSelected: Bool {
        !friends.isEmpty && friends.allSatisfy { selectedRecipientIDs.contains($0.id) }
    }

    /// At least one valid recipient is picked (gates the send button).
    var hasRecipientSelection: Bool { !resolvedRecipientIDs.isEmpty }

    /// Seed the strip the first time it has friends to show: the last people you
    /// sent to, or everyone if that's empty. Idempotent; no-ops with no friends.
    func seedRecipientSelectionIfNeeded() {
        guard !didSeedRecipients, !friends.isEmpty else { return }
        didSeedRecipients = true
        let valid = Set(friends.map(\.id))
        let last = Set(lastRecipientIDs).intersection(valid)
        selectedRecipientIDs = last.isEmpty ? valid : last
    }

    /// Toggle one friend in/out of the selection.
    func toggleRecipient(_ id: String) {
        if selectedRecipientIDs.contains(id) { selectedRecipientIDs.remove(id) }
        else { selectedRecipientIDs.insert(id) }
    }

    /// "everyone": select the whole roster, or clear it if already all selected.
    func toggleAllRecipients() {
        selectedRecipientIDs = isAllRecipientsSelected ? [] : Set(friends.map(\.id))
    }

    // MARK: - Sending (local-first)

    /// What the composer hands to the pipe: a dot-grid or a downscaled photo JPEG.
    enum ComposePayload {
        case dots(Grid)
        case photo(Data)
        case doodle(Data)
    }

    /// Persist locally FIRST (canvas + widget echo + queue), then push to CloudKit.
    /// A message is never lost to a network hiccup.
    func send(_ payload: ComposePayload, to recipientIDs: [String]) {
        let token = profile?.token ?? .placeholder
        let name = profile?.name ?? "You"
        let now = Date()

        let echo: DisplayDrawing
        switch payload {
        case .dots(let grid):
            GridStore.shared.save(grid)   // also restores the composer canvas
            echo = .dots(grid, senderID: "", senderName: name, token: token, sentAt: now)
        case .photo(let data):
            echo = .photo(data, senderID: "", senderName: name, token: token, sentAt: now)
        case .doodle(let data):
            echo = .doodle(data, senderID: "", senderName: name, token: token, sentAt: now)
        }
        GridStore.shared.saveLocalEcho(echo)

        // Record it in the inbox's "sent" feed. Resolve recipients to friends for
        // their token/name; an unknown id (rare) falls back to a placeholder. An
        // empty list means a local-only send (no friends picked).
        // ONE id per send: the sent-feed entry, the outbox item, and the CloudKit
        // record's `messageID` all share it — it's the key a reaction points back at.
        let messageID = UUID().uuidString
        let recipients: [FriendInfo] = recipientIDs.map { id in
            friends.first { $0.id == id } ?? FriendInfo(id: id, name: "friend", token: .placeholder)
        }
        // Honest from birth: a real send starts as .sending and only flushOutbox
        // promotes it to .sent; a local-only echo has nothing to deliver.
        let willDeliver = profile != nil && !recipientIDs.isEmpty
        GridStore.shared.appendSent(SentMessage(id: messageID, drawing: echo, recipients: recipients,
                                                status: willDeliver ? .sending : .localOnly))
        deliveryRevision &+= 1
        reloadDefaultWidget()

        guard let profile, !recipientIDs.isEmpty else { return }   // local-only send

        // The two-way loop is real: first send to a friend can prime notifications.
        notifications.noteLoopBecameReal()

        lastRecipientIDs = recipientIDs
        UserDefaults.standard.set(recipientIDs, forKey: "lastRecipients")

        let queued: QueuedSend
        switch payload {
        case .dots(let grid):
            queued = QueuedSend(id: messageID, kind: .dots, grid: grid, imageData: nil,
                                recipientIDs: recipientIDs, senderName: profile.name,
                                token: profile.token, createdAt: now)
        case .photo(let data):
            queued = QueuedSend(id: messageID, kind: .photo, grid: nil, imageData: data,
                                recipientIDs: recipientIDs, senderName: profile.name,
                                token: profile.token, createdAt: now)
        case .doodle(let data):
            queued = QueuedSend(id: messageID, kind: .doodle, grid: nil, imageData: data,
                                recipientIDs: recipientIDs, senderName: profile.name,
                                token: profile.token, createdAt: now)
        }
        outbox.append(queued)
        GridStore.shared.saveOutbox(outbox)

        Task { await flushWithProtection() }
    }

    /// True when there are sends waiting on connectivity.
    var hasPendingSends: Bool { !outbox.isEmpty }

    /// Pure transition for one outbox item after a flush attempt — kept free of
    /// I/O so the retry policy is unit-testable.
    enum FlushOutcome: Equatable {
        case sent
        case retrying(failedRecipientIDs: [String], attempts: Int)
        case gaveUp(failedRecipientIDs: [String])
    }

    nonisolated static func flushOutcome(after result: SharingService.SendResult,
                                         attemptsSoFar: Int) -> FlushOutcome {
        guard !result.succeeded else { return .sent }
        let attempts = attemptsSoFar + 1
        if result.isTerminal {
            return .gaveUp(failedRecipientIDs: result.failedRecipientIDs)
        }
        // Transient delivery failures remain durable until connectivity, account,
        // or CloudKit recovers. Dropping them after an arbitrary attempt count was
        // convenient for the UI but violated the outbox's no-loss contract.
        return .retrying(failedRecipientIDs: result.failedRecipientIDs, attempts: attempts)
    }

    // MARK: - Retry machinery

    /// The registered BGAppRefreshTask identifier (also in Info.plist).
    static let flushTaskID = "com.kolteaditya.dotgrid.flush"

    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var isFlushingOutbox = false
    @ObservationIgnored private var outboxFlushRequested = false

    /// Foreground retry loop: while anything is queued, back off 5s → 15s → 60s,
    /// then hold at 5 min. Runs only while the app is active; cancelled when the
    /// queue drains or the app backgrounds (the BG refresh takes over there).
    private func scheduleRetryLoop() {
        guard retryTask == nil, !outbox.isEmpty,
              UIApplication.shared.applicationState == .active else { return }
        retryTask = Task {
            let steps: [Double] = [5, 15, 60]
            var attempt = 0
            while !Task.isCancelled && !outbox.isEmpty {
                let delay = attempt < steps.count ? steps[attempt] : 300
                attempt += 1
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled || outbox.isEmpty { break }
                if isOnline { await flushOutbox() }
            }
            retryTask = nil
        }
    }

    private func cancelRetryLoop() {
        retryTask?.cancel()
        retryTask = nil
    }

    /// Backgrounding: stop the foreground loop and hand any unfinished sends to
    /// the system's background refresh (best effort, but no longer nothing).
    func onBackground() {
        cancelRetryLoop()
        if !outbox.isEmpty { Self.scheduleBackgroundFlush() }
    }

    /// Ask iOS for a background window to drain the outbox. The system decides
    /// when (or whether) it runs — the foreground paths remain the guarantee.
    static func scheduleBackgroundFlush() {
        let request = BGAppRefreshTaskRequest(identifier: flushTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Flush wrapped in a UIKit background task, so swiping the app away right
    /// after tapping send doesn't kill the upload mid-flight.
    func flushWithProtection() async {
        var token = UIBackgroundTaskIdentifier.invalid
        token = UIApplication.shared.beginBackgroundTask(withName: "dotdot.flush") {
            UIApplication.shared.endBackgroundTask(token)
            token = .invalid
        }
        await flushOutbox()
        if token != .invalid {
            UIApplication.shared.endBackgroundTask(token)
        }
    }

    func flushOutbox() async {
        outboxFlushRequested = true
        guard !isFlushingOutbox else { return }
        isFlushingOutbox = true
        defer { isFlushingOutbox = false }

        await flushReactions()
        guard let profile, isOnline, !outbox.isEmpty else { return }
        let senderID = participantID(for: profile.id)
        var attemptedIDs = Set<String>()

        while isOnline {
            outboxFlushRequested = false
            let ids = outbox.map(\.id).filter { !attemptedIDs.contains($0) }
            guard !ids.isEmpty else { break }
            for id in ids {
                guard !Task.isCancelled,
                      let item = outbox.first(where: { $0.id == id }) else { continue }
                attemptedIDs.insert(id)
                let result = await service.sendMessage(
                    kind: item.kind, grid: item.grid, imageData: item.imageData,
                    to: item.recipientIDs, from: profile, senderID: senderID,
                    messageID: item.id, sentAt: item.createdAt
                )
                // Surface the cause — a silent queue is undebuggable (this is what
                // let sends rot with the debug panel claiming "none").
                if let error = result.lastError {
                    lastError = "Send: \(error.localizedDescription)"
                } else if lastError?.hasPrefix("Send:") == true {
                    lastError = nil
                }
                switch Self.flushOutcome(after: result, attemptsSoFar: item.attempts) {
                case .sent:
                    outbox.removeAll { $0.id == item.id }
                    GridStore.shared.updateSentStatus(id: item.id, status: .sent)
                case .gaveUp(let failedIDs):
                    outbox.removeAll { $0.id == item.id }
                    // The sent tab shows "not sent yet" with a resend.
                    GridStore.shared.updateSentStatus(id: item.id, status: .failed,
                                                      failedRecipientIDs: failedIDs)
                    notifySendGaveUp(messageID: item.id)   // only on giving up, never per retry
                case .retrying(let failedIDs, let attempts):
                    if let index = outbox.firstIndex(where: { $0.id == item.id }) {
                        outbox[index].recipientIDs = failedIDs
                        outbox[index].attempts = attempts
                        outbox[index].lastErrorDescription = result.lastError?.localizedDescription
                    }
                    GridStore.shared.updateSentStatus(id: item.id, status: .sending,
                                                      failedRecipientIDs: failedIDs)
                }
                GridStore.shared.saveOutbox(outbox)
                deliveryRevision &+= 1
            }

            // A send appended while CloudKit was awaiting set the request flag and
            // is not in attemptedIDs, so the next pass picks it up. Existing failed
            // items wait for the scheduled backoff instead of hot-looping.
            if !outboxFlushRequested { break }
        }
        // Anything left keeps retrying on the foreground backoff loop.
        if !outbox.isEmpty { scheduleRetryLoop() }
    }

    /// A send just went .failed. Foregrounded → toast with a retry; backgrounded →
    /// one local notification routed to the drawing in sent (the resend lives there).
    private func notifySendGaveUp(messageID: String) {
        if UIApplication.shared.applicationState == .active {
            showToast("couldn't send your dotdot", icon: "exclamationmark.triangle.fill",
                      actionTitle: "retry") { [weak self] in
                self?.resendMessage(id: messageID)
            }
        } else {
            Task { await PushNotifier.notifySendFailed(messageID: messageID) }
        }
    }

    /// Resend from the sent tab: retarget exactly the recipients still owed, reset
    /// the attempt budget, and flush now. Works whether the item is still queued
    /// (retrying) or was dropped when it gave up (rebuilt from the sent echo, which
    /// carries the full payload).
    func resendMessage(id: String) {
        guard let message = GridStore.shared.sentHistory().first(where: { $0.id == id }) else { return }
        if let index = outbox.firstIndex(where: { $0.id == id }) {
            outbox[index].attempts = 0
            outbox[index].lastErrorDescription = nil
        } else {
            guard let profile else { return }
            let targets = message.failedRecipientIDs.isEmpty
                ? message.recipients.map(\.id)
                : message.failedRecipientIDs
            guard !targets.isEmpty else { return }
            outbox.append(QueuedSend(id: id, kind: message.drawing.kind, grid: message.drawing.grid,
                                     imageData: message.drawing.imageData, recipientIDs: targets,
                                     senderName: profile.name, token: profile.token,
                                     createdAt: message.sentAt))
        }
        GridStore.shared.saveOutbox(outbox)
        GridStore.shared.updateSentStatus(id: id, status: .sending)
        Task { await flushWithProtection() }
    }

    // MARK: - Reactions

    /// A reaction op waiting on connectivity (nil emoji = un-react).
    private struct QueuedReaction: Codable, Equatable {
        var emoji: String?
        var messageID: String?
        var drawingSentAt: Date
        var recipientID: String
    }
    private static let reactionOutboxKey = "reactionOutbox"

    /// React to a received dotdot — tapping your current emoji again un-reacts.
    /// Local-first: the feed + widget update instantly; CloudKit follows (queued
    /// offline, like sends). Returns the drawing's new reaction for the UI.
    @discardableResult
    func react(with emoji: String, to drawing: DisplayDrawing) -> String? {
        guard !drawing.senderID.isEmpty else { return drawing.myReaction }
        let newValue = drawing.myReaction == emoji ? nil : emoji

        GridStore.shared.applyMyReaction(newValue, senderID: drawing.senderID, sentAt: drawing.sentAt)
        deliveryRevision &+= 1
        reloadReceivedWidgets()   // the emoji sticks on the widget

        var queue = loadReactionQueue()
        // A newer op for the same dotdot supersedes any queued one.
        queue.removeAll { $0.recipientID == drawing.senderID && $0.drawingSentAt == drawing.sentAt }
        queue.append(QueuedReaction(emoji: newValue, messageID: drawing.messageID,
                                    drawingSentAt: drawing.sentAt, recipientID: drawing.senderID))
        saveReactionQueue(queue)
        Task { await flushReactions() }
        return newValue
    }

    @ObservationIgnored private var isFlushingReactions = false
    @ObservationIgnored private var reactionFlushRequested = false

    private func flushReactions() async {
        reactionFlushRequested = true
        guard !isFlushingReactions else { return }
        guard let profile, isOnline else { return }
        isFlushingReactions = true
        defer { isFlushingReactions = false }
        let reactorID = participantID(for: profile.id)
        var attempted: [QueuedReaction] = []

        while isOnline {
            reactionFlushRequested = false
            let queue = loadReactionQueue().filter { !attempted.contains($0) }
            guard !queue.isEmpty else { break }
            for op in queue {
                attempted.append(op)
                let succeeded: Bool
                if let emoji = op.emoji {
                    succeeded = await service.sendReaction(
                        emoji: emoji, messageID: op.messageID,
                        drawingSentAt: op.drawingSentAt,
                        to: op.recipientID, from: profile, reactorID: reactorID)
                } else {
                    await service.removeReaction(messageID: op.messageID,
                                                 drawingSentAt: op.drawingSentAt,
                                                 reactorID: reactorID)
                    succeeded = true
                }
                if succeeded {
                    // Remove only this exact operation from the CURRENT queue. A
                    // newer tap written while we awaited CloudKit must survive.
                    var current = loadReactionQueue()
                    current.removeAll { $0 == op }
                    saveReactionQueue(current)
                }
            }
            if !reactionFlushRequested { break }
        }
    }

    private func loadReactionQueue() -> [QueuedReaction] {
        guard let data = UserDefaults.standard.data(forKey: Self.reactionOutboxKey) else { return [] }
        return (try? JSONDecoder().decode([QueuedReaction].self, from: data)) ?? []
    }

    private func saveReactionQueue(_ queue: [QueuedReaction]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(queue), forKey: Self.reactionOutboxKey)
    }

    // MARK: - Inbox unread / shimmer

    private static let inboxSeenKey = "inboxLastSeenAt"

    /// A friend's dotdot is unread if it arrived after the last time the inbox was
    /// opened. Sent dotdots and your own echoes never count.
    private func computeInboxUnread() -> Bool {
        let seen = (UserDefaults.standard.object(forKey: Self.inboxSeenKey) as? Date) ?? .distantPast
        let newest = GridStore.shared.latestReceivedAt() ?? .distantPast
        return newest > seen
    }

    private func refreshInboxUnread() { inboxHasUnread = computeInboxUnread() }

    /// Opening the inbox marks everything seen and stops the shimmer.
    func markInboxSeen() {
        UserDefaults.standard.set(Date(), forKey: Self.inboxSeenKey)
        inboxHasUnread = false
    }

    // MARK: - Helpers

    private func pullIncoming() async {
        guard case let .available(userID) = account else { return }
        do {
            let drawings = try await service.fetchIncoming(recipientIDs: incomingRecipientIDs(for: userID))
            if lastError?.hasPrefix("Incoming fetch:") == true { lastError = nil }
            _ = landIncoming(drawings)
        } catch {
            lastError = "Incoming fetch: \(error.localizedDescription)"
        }
        // Reactions to dotdots I sent (updates the sent feed; no widget content).
        if let reactions = try? await service.fetchReactions(
            recipientIDs: incomingRecipientIDs(for: userID)), !reactions.isEmpty {
            deliveryRevision &+= 1
        }
        refreshInboxUnread()
    }

    /// Apply the shared post-ingest effects exactly once for newly inserted rows.
    @discardableResult
    private func landIncoming(_ drawings: [DisplayDrawing]) -> Bool {
        guard !drawings.isEmpty else { return false }
        refreshInboxUnread()
        reloadReceivedWidgets()
        deliveryRevision &+= 1
        if inboxHasUnread { inboxShimmerNonce &+= 1 }
        notifications.noteReceivedFromFriend()
        PushNotifier.recordDrawingArrivals(drawings)
        return true
    }

    private func reloadDefaultWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: GridStore.widgetKind)
    }

    private func reloadReceivedWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: GridStore.widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: GridStore.friendWidgetKind)
    }

    private func participantID(for userID: String) -> String {
        service.participantID(for: userID)
    }

    private func incomingRecipientIDs(for userID: String) -> [String] {
        [userID, participantID(for: userID)]
    }

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let wasOffline = !self.isOnline
                self.isOnline = online
                if online && wasOffline { await self.flushOutbox() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dotdot.network"))
    }
}
