//
//  ComposerView.swift
//  Dot Grid
//
//  Hosts the shared top bar and the Dots | Photo mode switch. Both composers stay
//  mounted (toggled by opacity) so each mode keeps its in-progress state while the
//  app is open. The switch is in-app only — there is no home-screen widget swiping.
//

import SwiftUI

enum ComposeMode: String { case dots, photo, doodle }

/// The one sheet that can be up over the composer at a time. A single `.sheet(item:)`
/// avoids the multiple-`.sheet`-on-one-view presentation glitches.
private enum ActiveSheet: Int, Identifiable {
    case inbox, addFriend, settings, debug, notificationPriming
    var id: Int { rawValue }
}

struct ComposerView: View {
    @Environment(AppModel.self) private var appModel

    @AppStorage("composeMode") private var modeRaw = ComposeMode.dots.rawValue
    @AppStorage("accentColorIndex") private var accentIndex = 0   // drives the wordmark tint
    @State private var activeSheet: ActiveSheet?
    @State private var shimmerPhase: CGFloat = 1   // 0 = off-screen left, 1 = off-screen right (rest)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var modePill

    private var mode: ComposeMode { ComposeMode(rawValue: modeRaw) ?? .dots }

    var body: some View {
        ZStack {
            Palette.screenBackground.ignoresSafeArea()
            VStack(spacing: 14) {
                topBar
                modeToggle
                ZStack {
                    ContentView()
                        .opacity(mode == .dots ? 1 : 0)
                        .allowsHitTesting(mode == .dots)
                    PhotoComposerView(isActive: mode == .photo)
                        .opacity(mode == .photo ? 1 : 0)
                        .allowsHitTesting(mode == .photo)
                    DoodleComposerView()
                        .opacity(mode == .doodle ? 1 : 0)
                        .allowsHitTesting(mode == .doodle)
                }
            }
            .padding(20)
            // The caption editor's keyboard must never reflow the home layout — the
            // board would shrink. (No other inline text input lives on this screen;
            // sheets present separately and keep their own keyboard avoidance.)
            .ignoresSafeArea(.keyboard)
        }
        .font(DotFont.ui(17))   // Hanken Grotesk is the default UI/body font
        .textCase(.lowercase)   // the whole app reads lowercase
        .preferredColorScheme(.dark)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .inbox:               InboxView()
            case .addFriend:           AddFriendView()
            case .settings:            SettingsView()
            case .debug:               DebugView()
            case .notificationPriming: NotificationPrimingSheet()
            }
        }
        .onAppear { playInboxShimmer() }                                   // cold launch
        .task { await appModel.notifications.refresh() }                   // live notif status
        .onChange(of: appModel.inboxHasUnread) { _, unread in              // first unread arrives
            if unread { playInboxShimmer() }
        }
        .onChange(of: appModel.inboxShimmerNonce) { _, _ in playInboxShimmer() }   // warm open / live arrival
        // The soft notification ask, requested by an automatic trigger (first send /
        // pairing / received). Present it only once we're frontmost; a short delay lets
        // any transient sheet (e.g. the recipient picker) finish dismissing first.
        .onChange(of: appModel.notifications.wantsPriming) { _, wants in
            if wants { scheduleNotificationPriming() }
        }
        .onChange(of: activeSheet) { _, sheet in
            if sheet == nil && appModel.notifications.wantsPriming { scheduleNotificationPriming() }
        }
        // Tapping the widget deep-links straight to the inbox (received feed) — the
        // fastest path from "saw it on the home screen" to reacting to it.
        .onOpenURL { url in
            guard url.scheme == "dotdot", url.host == "inbox" else { return }
            activeSheet = .inbox
        }
    }

    private func scheduleNotificationPriming() {
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            let gate = appModel.notifications
            guard gate.wantsPriming, gate.canPrime, activeSheet == nil else {
                if !gate.canPrime { gate.wantsPriming = false }   // status changed under us
                return
            }
            activeSheet = .notificationPriming   // sheet's onAppear consumes wantsPriming
        }
    }

    /// Plays the wordmark sheen: two clean sweeps, then rest. Resetting the phase in
    /// a follow-up tick guarantees the animation actually runs (a same-transaction
    /// 1→0→1 would coalesce to no change), and the reset point is off-screen so
    /// there's no flash. No-op when there's nothing unread or under Reduce Motion.
    private func playInboxShimmer() {
        guard appModel.inboxHasUnread, !reduceMotion else { return }
        shimmerPhase = 0
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.95).repeatCount(2, autoreverses: false)) {
                shimmerPhase = 1
            }
        }
    }

    // MARK: Top bar (shared across modes)

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { activeSheet = .inbox } label: { wordmark }
                    .buttonStyle(SquishyButtonStyle())
                    .accessibilityLabel("dotdot inbox")
                Spacer()
                if appModel.hasPendingSends {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("\(appModel.outbox.count)")
                    }
                    .font(DotFont.mono(12, bold: true))
                    .foregroundStyle(.white.opacity(0.55))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(appModel.outbox.count) waiting to send")
                }
                Button { activeSheet = .addFriend } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Palette.boardBackground))
                }
                .buttonStyle(SquishyButtonStyle())
                .accessibilityLabel("add a friend")
                if let me = appModel.profile {
                    TokenBadge(token: me.token, size: 32)
                        .onTapGesture { activeSheet = .settings }
                        .onLongPressGesture { activeSheet = .debug }
                        .accessibilityElement()
                        .accessibilityLabel("settings")
                        .accessibilityAddTraits(.isButton)
                }
            }
            if !appModel.isSignedIn {
                iCloudBanner
            }
        }
    }

    /// The DOTDOT wordmark glyphs — Hanken Grotesk italic, a heavier "dot" + a
    /// featherweight "dot" (medium + extralight, tracking pulled in tight, per the
    /// Figma spec). Kept as a `Text` so it serves as both the visible mark and the
    /// shimmer's mask, guaranteeing the sheen clips exactly to the letters.
    private var wordmarkText: Text {
        (
            Text("dot").font(.custom("HankenGrotesk-MediumItalic", fixedSize: 32))
            + Text("dot").font(.custom("HankenGrotesk-ExtraLightItalic", fixedSize: 32))
        )
        .tracking(-2.56)
    }

    /// Tinted with whatever dot color is currently selected (a tiny easter egg, the
    /// logo follows your picker) and overlaid with the inbox sheen.
    private var wordmark: some View {
        wordmarkText
            .foregroundStyle(Palette.color(at: accentIndex))
            .overlay { inboxShimmer }
            .animation(.easeInOut(duration: 0.2), value: accentIndex)
    }

    /// One bright sheen sweeping left→right across the wordmark to flag unread inbox
    /// dotdots. Soft-edged so it never reads as a hard band, masked to the glyphs,
    /// fully off-screen at rest, and only present when there's something unread (and
    /// motion is allowed) — so it leaves no static artifact once the inbox is opened.
    @ViewBuilder
    private var inboxShimmer: some View {
        if appModel.inboxHasUnread && !reduceMotion {
            GeometryReader { proxy in
                let w = proxy.size.width
                let band = max(w * 0.42, 38)
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0),    location: 0),
                        .init(color: .white.opacity(0.85), location: 0.5),
                        .init(color: .white.opacity(0),    location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: -band + shimmerPhase * (w + band))
            }
            .mask(wordmarkText)
            .allowsHitTesting(false)
        }
    }

    private var iCloudBanner: some View {
        Button {
            Task { await appModel.onForeground() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "icloud.slash.fill")
                Text("Sign into iCloud to send & receive")
                    .font(.footnote.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.boardBackground))
        }
        .buttonStyle(.plain)
    }

    // MARK: Mode toggle

    private var modeToggle: some View {
        HStack(spacing: 4) {
            segment(.dots, label: "Dots", icon: "circle.grid.3x3.fill")
            segment(.photo, label: "Photo", icon: "photo.fill")
            segment(.doodle, label: "Doodle", icon: "scribble.variable")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.boardBackground))
    }

    private func segment(_ target: ComposeMode, label: String, icon: String) -> some View {
        let selected = mode == target
        return Button {
            withAnimation(.snappy(duration: 0.25)) { modeRaw = target.rawValue }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
            .font(DotFont.ui(15, weight: .bold))
            .foregroundStyle(selected ? Theme.ink : .white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.cream)
                        .matchedGeometryEffect(id: "modePill", in: modePill)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
