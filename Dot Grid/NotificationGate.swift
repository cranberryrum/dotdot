//
//  NotificationGate.swift
//  Dot Grid
//
//  Owns the notification-PERMISSION flow (not the push payloads — those are a separate
//  pass). The rules it enforces:
//
//  • The live OS status is the single source of truth, read fresh from
//    UNUserNotificationCenter on every relevant screen appear + on foreground. We never
//    trust a cached boolean — the user can flip it in iOS Settings behind our back.
//  • The one-shot rule: iOS grants exactly one system prompt. We only ever call
//    requestAuthorization in direct response to an explicit "yes" in our own soft sheet
//    (NotificationPrimingSheet) — never on launch, never speculatively. Our sheet's
//    decline is always soft, so it costs nothing and the OS prompt stays available.
//  • Sending never depends on any of this.
//

import SwiftUI
import UserNotifications
import UIKit

@MainActor
@Observable
final class NotificationGate {
    /// Live OS authorization status. Refreshed on every relevant appear + foreground.
    private(set) var status: UNAuthorizationStatus = .notDetermined

    /// One-shot signal: an automatic trigger (first send-with-a-friend / first pairing /
    /// first received) wants the soft sheet. ComposerView observes this and presents it
    /// once it's frontmost. Explicit asks (settings row, feed nudge) present directly.
    var wantsPriming = false

    /// Persisted once the feed nudge is crossed off, so it doesn't return every visit.
    private(set) var feedNudgeDismissed: Bool

    private let defaults = UserDefaults.standard
    private enum Key {
        static let primed = "notif.primed"            // soft sheet shown at least once
        static let declined = "notif.declined"        // user tapped "not now"
        static let reprised = "notif.reprised"        // the one allowed re-prime is spent
        static let feedDismissed = "notif.feedNudgeDismissed"
        static let drawingsOff = "notif.type.drawings.off"
        static let friendsOff = "notif.type.friends.off"
        static let reactionsOff = "notif.type.reactions.off"
    }

    init() {
        feedNudgeDismissed = defaults.bool(forKey: Key.feedDismissed)
        drawingAlerts = !defaults.bool(forKey: Key.drawingsOff)
        friendAlerts = !defaults.bool(forKey: Key.friendsOff)
        reactionAlerts = !defaults.bool(forKey: Key.reactionsOff)
    }

    // MARK: - Per-type alert toggles (defaults ON; stored inverted so no-key = on).
    // Every visible push checks its toggle before surfacing — the toggles never
    // touch the silent data flow.

    var drawingAlerts: Bool = true {
        didSet { defaults.set(!drawingAlerts, forKey: Key.drawingsOff) }
    }
    var friendAlerts: Bool = true {
        didSet { defaults.set(!friendAlerts, forKey: Key.friendsOff) }
    }
    var reactionAlerts: Bool = true {
        didSet { defaults.set(!reactionAlerts, forKey: Key.reactionsOff) }
    }

    private var hasPrimed: Bool { defaults.bool(forKey: Key.primed) }
    private var hasDeclined: Bool { defaults.bool(forKey: Key.declined) }
    private var hasReprised: Bool { defaults.bool(forKey: Key.reprised) }

    // MARK: - Live status

    /// Read the LIVE OS status. Call on every relevant appear + on foreground.
    func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// True when our soft prompt can still meaningfully run (the OS prompt is available).
    var canPrime: Bool { status == .notDetermined }

    /// The feed nudge shows only when undecided or denied, and not yet crossed off.
    /// The debug replay toggle bypasses the dismissal (never the OS permission state).
    var shouldShowFeedNudge: Bool {
        (status == .notDetermined || status == .denied)
            && (!feedNudgeDismissed || DebugFlags.replayFirstRuns)
    }

    // MARK: - Automatic triggers (set the signal; ComposerView presents when frontmost)

    /// First moment the two-way loop is real — first send-with-a-friend or first
    /// pairing, whichever comes first. Primes once; no-op if already primed or decided.
    func noteLoopBecameReal() {
        guard status == .notDetermined, !hasPrimed else { return }
        wantsPriming = true
    }

    /// One extra re-prime after a "not now" — e.g. the first drawing from a real friend.
    func noteReceivedFromFriend() {
        guard status == .notDetermined, hasPrimed, hasDeclined, !hasReprised else { return }
        defaults.set(true, forKey: Key.reprised)
        wantsPriming = true
    }

    // MARK: - Soft sheet outcomes (NotificationPrimingSheet calls these)

    /// Mark the soft sheet as shown (so automatic triggers stop) and consume the signal.
    func notePrimingShown() {
        defaults.set(true, forKey: Key.primed)
        wantsPriming = false
    }

    /// The OS prompt. ONLY ever called from the soft sheet's explicit "turn on".
    func requestAuthorization() async {
        defaults.set(true, forKey: Key.primed)
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        await refresh()
    }

    /// Soft decline — no penalty, the OS prompt stays available; enables one reprise.
    func declinePriming() {
        defaults.set(true, forKey: Key.primed)
        defaults.set(true, forKey: Key.declined)
    }

    // MARK: - Feed nudge

    func dismissFeedNudge() {
        feedNudgeDismissed = true
        defaults.set(true, forKey: Key.feedDismissed)
    }

    // MARK: - Deep link to iOS Settings (denied → re-enable, or authorized → manage)

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
