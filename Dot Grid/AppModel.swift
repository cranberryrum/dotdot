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

    /// An invite link tapped before onboarding finished; applied afterwards.
    private var pendingInviteToken: String?

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
        if let remote = try? await service.fetchMyProfile(userID: userID) {
            profile = remote
            GridStore.shared.saveProfile(remote)
        }

        phase = profile == nil ? .onboarding : .ready

        guard profile != nil else { return }   // finish onboarding first

        await service.ensureSubscription(myID: userID)
        await refreshFriends()
        await pullIncoming()
        await flushOutbox()
        if let token = pendingInviteToken { await applyInvite(token: token) }
    }

    /// Lighter refresh when the app returns to the foreground.
    func onForeground() async {
        account = await service.accountState()
        if case .available = account, profile != nil {
            if phase == .iCloudUnavailable { await bootstrap(); return }
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
        let count = await service.fetchIncoming(myID: userID)
        if count > 0 { WidgetCenter.shared.reloadAllTimelines() }
    }

    // MARK: - Onboarding

    /// Step 1 of onboarding: create the profile (and apply any held invite). Stays
    /// on the onboarding flow so step 2 (add a friend) can show the user's link.
    func createProfile(name: String, token: IdentityToken) async throws {
        guard case let .available(userID) = account else { throw PairingError.notSignedIn }
        let saved = try await service.saveMyProfile(userID: userID, name: name, token: token, existing: profile)
        profile = saved
        GridStore.shared.saveProfile(saved)
        await service.ensureSubscription(myID: userID)
        if let token = pendingInviteToken { await applyInvite(token: token) }
        await refreshFriends()
        await pullIncoming()
    }

    /// Step 2 done (added a friend or skipped) → land in the composer.
    func markReady() { phase = .ready }

    // MARK: - Pairing

    func generateCode() async throws -> String {
        guard case let .available(userID) = account else { throw PairingError.notSignedIn }
        return try await service.generateCode(ownerID: userID)
    }

    func inviteLink() -> URL? {
        profile.map { service.inviteLink(for: $0) }
    }

    func addFriend(byCode code: String) async throws {
        guard case let .available(userID) = account else { throw PairingError.notSignedIn }
        try await service.redeemCode(code, myID: userID)
        await refreshFriends()
    }

    func handleInviteURL(_ url: URL) {
        guard let token = Self.inviteToken(from: url) else { return }
        Task {
            if profile != nil { await applyInvite(token: token) }
            else { pendingInviteToken = token }   // hold until onboarding completes
        }
    }

    private func applyInvite(token: String) async {
        guard case let .available(userID) = account else { pendingInviteToken = token; return }
        pendingInviteToken = nil
        do {
            try await service.redeemInvite(token: token, myID: userID)
            await refreshFriends()
            banner = "You're connected! 🎉"
        } catch let error as PairingError {
            banner = error.errorDescription
        } catch {
            banner = PairingError.generic.errorDescription
        }
    }

    private func refreshFriends() async {
        guard case let .available(userID) = account else { return }
        if let list = try? await service.fetchFriends(myID: userID) {
            friends = list
            GridStore.shared.saveRoster(list)
        }
    }

    // MARK: - Sending (local-first)

    /// Persist locally FIRST (canvas + widget echo + queue), then push to CloudKit.
    /// A drawing is never lost to a network hiccup.
    func send(_ grid: Grid, to recipientIDs: [String]) {
        GridStore.shared.save(grid)
        GridStore.shared.saveLocalEcho(grid: grid, token: profile?.token ?? .placeholder)
        WidgetCenter.shared.reloadAllTimelines()

        guard let profile, !recipientIDs.isEmpty else { return }   // local-only send

        lastRecipientIDs = recipientIDs
        UserDefaults.standard.set(recipientIDs, forKey: "lastRecipients")

        let queued = QueuedSend(
            id: UUID().uuidString,
            grid: grid,
            recipientIDs: recipientIDs,
            senderName: profile.name,
            token: profile.token,
            createdAt: Date()
        )
        outbox.append(queued)
        GridStore.shared.saveOutbox(outbox)

        Task { await flushOutbox() }
    }

    /// True when there are sends waiting on connectivity.
    var hasPendingSends: Bool { !outbox.isEmpty }

    func flushOutbox() async {
        guard let profile, isOnline, !outbox.isEmpty else { return }
        var remaining: [QueuedSend] = []
        for item in outbox {
            let failed = await service.sendDrawing(grid: item.grid, to: item.recipientIDs, from: profile)
            if !failed.isEmpty {
                remaining.append(QueuedSend(
                    id: item.id, grid: item.grid, recipientIDs: failed,
                    senderName: item.senderName, token: item.token, createdAt: item.createdAt
                ))
            }
        }
        outbox = remaining
        GridStore.shared.saveOutbox(outbox)
    }

    // MARK: - Helpers

    private func pullIncoming() async {
        guard case let .available(userID) = account else { return }
        let count = await service.fetchIncoming(myID: userID)
        if count > 0 { WidgetCenter.shared.reloadAllTimelines() }
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

    /// Parse the invite token from either the universal link or the custom scheme.
    static func inviteToken(from url: URL) -> String? {
        // https://dotdot.app/i/<token>
        if url.host == "dotdot.app", url.pathComponents.count >= 3, url.pathComponents[1] == "i" {
            return url.pathComponents[2]
        }
        // dotdot://invite?t=<token>
        if url.scheme == "dotdot" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            return comps?.queryItems?.first(where: { $0.name == "t" })?.value
        }
        return nil
    }
}
