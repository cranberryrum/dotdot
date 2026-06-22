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

    /// Transient message surfaced as a banner (e.g. pairing results).
    var banner: String?

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
        if count > 0 { WidgetCenter.shared.reloadAllTimelines() }
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
        for key in ["lastUserRecordName", "lastDrawingFetch", "redeemAttempts", "lastRecipients", "dotdotDeviceID"] {
            defaults.removeObject(forKey: key)
        }
        profile = nil
        friends = []
        outbox = []
        lastRecipientIDs = []
        lastError = nil
        WidgetCenter.shared.reloadAllTimelines()
        phase = .onboarding
    }

    // MARK: - Pairing

    func generateCode() async throws -> String {
        guard case let .available(userID) = account else { throw PairingError.notSignedIn }
        return try await service.generateCode(ownerID: userID, ownerParticipantID: participantID(for: userID))
    }

    func addFriend(byCode code: String) async throws {
        guard case let .available(userID) = account else { throw PairingError.notSignedIn }
        try await service.redeemCode(code, myID: userID, myParticipantID: participantID(for: userID))
        await refreshFriends()
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
        }
        GridStore.shared.saveLocalEcho(echo)
        WidgetCenter.shared.reloadAllTimelines()

        guard let profile, !recipientIDs.isEmpty else { return }   // local-only send

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

    // MARK: - Helpers

    private func pullIncoming() async {
        guard case let .available(userID) = account else { return }
        do {
            let count = try await service.fetchIncoming(recipientIDs: incomingRecipientIDs(for: userID))
            if lastError?.hasPrefix("Incoming fetch:") == true { lastError = nil }
            if count > 0 { WidgetCenter.shared.reloadAllTimelines() }
        } catch {
            lastError = "Incoming fetch: \(error.localizedDescription)"
        }
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
