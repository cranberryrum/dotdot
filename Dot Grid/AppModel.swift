//
//  AppModel.swift
//  Dot Grid
//
//  The orchestration brain between the composer UI, the local GridStore/App Group
//  pipe, and CloudKit. Owns iCloud state, identity, friends, and the local-first
//  send queue. The widget never sees this — it only reads GridStore.
//

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
        outbox = GridStore.shared.loadOutbox()
        lastRecipientIDs = UserDefaults.standard.stringArray(forKey: "lastRecipients") ?? []
        inboxHasUnread = computeInboxUnread()   // from cache, so the cold launch knows immediately
    }

    // MARK: - Lifecycle

    func start() {
        guard !didStart else { return }
        didStart = true
        startNetworkMonitor()
        Task { await bootstrap() }
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
            UserDefaults.standard.removeObject(forKey: Self.inboxSeenKey)
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

        await service.ensureSubscription(userID: userID, participantID: participantID(for: userID))
        await refreshFriends()
        await pullIncoming()
        await flushOutbox()
    }

    /// Lighter refresh when the app returns to the foreground.
    func onForeground() async {
        await notifications.refresh()   // user may have changed it in iOS Settings while away
        account = await service.accountState()
        if case let .available(userID) = account, profile != nil {
            if phase == .iCloudUnavailable { await bootstrap(); return }
            // Re-assert the push subscription each foreground — idempotent, and it
            // self-heals if the very first attempt failed (e.g. before the
            // recipientID index existed), so the recipient's widget gets pushes.
            await service.ensureSubscription(userID: userID, participantID: participantID(for: userID))
            await refreshFriends()   // pick up friends added by the other party
            await pullIncoming()
            await flushOutbox()
            if inboxHasUnread { inboxShimmerNonce &+= 1 }   // warm open with unread → shimmer
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
    /// where `account` hasn't been resolved yet.
    func handlePush() async {
        if case .available = account {} else { account = await service.accountState() }
        guard case let .available(userID) = account else { return }
        await refreshFriends()   // a push may mean a new friendship, not just a drawing
        let count = (try? await service.fetchIncoming(recipientIDs: incomingRecipientIDs(for: userID))) ?? 0
        refreshInboxUnread()
        if count > 0 {
            WidgetCenter.shared.reloadAllTimelines()
            if inboxHasUnread { inboxShimmerNonce &+= 1 }   // live arrival → shimmer next render
            notifications.noteReceivedFromFriend()          // the one allowed re-prime
        }
    }

    // MARK: - Onboarding

    /// Step 1 of onboarding: create the profile. Stays on the onboarding flow so
    /// step 2 (add a friend) can run before landing in the composer.
    func createProfile(name: String, token: IdentityToken) async throws {
        guard case let .available(userID) = account else { throw PairingError.notSignedIn }
        let saved = try await service.saveMyProfile(userID: userID, name: name, token: token, existing: profile)
        profile = saved
        GridStore.shared.saveProfile(saved)
        await service.ensureSubscription(userID: userID, participantID: participantID(for: userID))
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
        for key in ["lastUserRecordName", "lastDrawingFetch", "redeemAttempts", "lastRecipients", "dotdotDeviceID", Self.inboxSeenKey] {
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
        await refreshFriends()
        // First successful pairing makes the loop real — prime once if that's first.
        notifications.noteLoopBecameReal()
    }

    /// Public refresh for the friends screen (pull the latest roster from CloudKit).
    func reloadFriends() async { await refreshFriends() }

    /// Remove a friend on both sides (deletes the shared Friendship record), and
    /// update the local roster immediately.
    func removeFriend(_ friend: FriendInfo) async {
        guard case let .available(userID) = account else { return }
        await service.removeFriend(friend.id, myID: userID, myParticipantID: participantID(for: userID))
        friends.removeAll { $0.id == friend.id }
        GridStore.shared.saveRoster(friends)
    }

    private func refreshFriends() async {
        guard case let .available(userID) = account else { return }
        do {
            let list = try await service.fetchFriends(myID: userID, myParticipantID: participantID(for: userID))
            friends = list
            GridStore.shared.saveRoster(list)
            if lastError?.hasPrefix("Friends fetch:") == true { lastError = nil }
        } catch {
            lastError = "Friends fetch: \(error.localizedDescription)"
        }
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
        let recipients: [FriendInfo] = recipientIDs.map { id in
            friends.first { $0.id == id } ?? FriendInfo(id: id, name: "friend", token: .placeholder)
        }
        GridStore.shared.appendSent(SentMessage(id: UUID().uuidString, drawing: echo, recipients: recipients))

        WidgetCenter.shared.reloadAllTimelines()

        guard let profile, !recipientIDs.isEmpty else { return }   // local-only send

        // The two-way loop is real: first send to a friend can prime notifications.
        notifications.noteLoopBecameReal()

        lastRecipientIDs = recipientIDs
        UserDefaults.standard.set(recipientIDs, forKey: "lastRecipients")

        let queued: QueuedSend
        switch payload {
        case .dots(let grid):
            queued = QueuedSend(id: UUID().uuidString, kind: .dots, grid: grid, imageData: nil,
                                recipientIDs: recipientIDs, senderName: profile.name,
                                token: profile.token, createdAt: now)
        case .photo(let data):
            queued = QueuedSend(id: UUID().uuidString, kind: .photo, grid: nil, imageData: data,
                                recipientIDs: recipientIDs, senderName: profile.name,
                                token: profile.token, createdAt: now)
        case .doodle(let data):
            queued = QueuedSend(id: UUID().uuidString, kind: .doodle, grid: nil, imageData: data,
                                recipientIDs: recipientIDs, senderName: profile.name,
                                token: profile.token, createdAt: now)
        }
        outbox.append(queued)
        GridStore.shared.saveOutbox(outbox)

        Task { await flushOutbox() }
    }

    /// True when there are sends waiting on connectivity.
    var hasPendingSends: Bool { !outbox.isEmpty }

    func flushOutbox() async {
        guard let profile, isOnline, !outbox.isEmpty else { return }
        let senderID = participantID(for: profile.id)
        var remaining: [QueuedSend] = []
        for item in outbox {
            let failed = await service.sendMessage(
                kind: item.kind, grid: item.grid, imageData: item.imageData,
                to: item.recipientIDs, from: profile, senderID: senderID
            )
            if !failed.isEmpty {
                var retry = item
                retry.recipientIDs = failed
                remaining.append(retry)
            }
        }
        outbox = remaining
        GridStore.shared.saveOutbox(outbox)
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
            let count = try await service.fetchIncoming(recipientIDs: incomingRecipientIDs(for: userID))
            if lastError?.hasPrefix("Incoming fetch:") == true { lastError = nil }
            if count > 0 {
                WidgetCenter.shared.reloadAllTimelines()
                notifications.noteReceivedFromFriend()   // the one allowed re-prime
            }
        } catch {
            lastError = "Incoming fetch: \(error.localizedDescription)"
        }
        refreshInboxUnread()
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
