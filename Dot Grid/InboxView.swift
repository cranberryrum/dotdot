//
//  InboxView.swift
//  Dot Grid
//
//  The inbox bottom sheet, opened by tapping the "dotdot" wordmark. A sticky,
//  page-level tab switches between two single-column feeds — dotdots received from
//  friends and dotdots you've sent. Tapping a received one enlarges it to a
//  peek; the sent feed just scrolls (no peek).
//
//  History is read from the App Group (GridStore): `saveReceived` appends to the
//  received feed, `AppModel.send` appends to the sent feed. Both are capped, so the
//  feeds show recent activity rather than all-time.
//

import SwiftUI
import UIKit

private enum InboxTab { case received, sent }

/// One row's worth of display data, unified across the received + sent feeds so the
/// card and the peek overlay render the same way.
private struct InboxEntry: Identifiable {
    let id: String
    let drawing: DisplayDrawing
    let token: IdentityToken   // sender (received) or first recipient (sent)
    let title: String          // "alice" (received) · "to alice +2" (sent)
    var reactions: [ReactionInfo] = []   // sent feed: who reacted with what
    var sendStatus: SentMessage.SendStatus?   // sent feed: honest delivery state
    var messageID: String?                    // sent feed: resend target
}

/// The tray's quick picks; the "+" opens the full grid.
private let quickReactions = ["❤️", "😂", "😮", "🥹", "🔥"]

/// The bottom-sheet grid. Curated, loud, dotdot-flavored.
private let allReactions: [String] = [
    "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💘", "💖", "💝", "🫶",
    "😂", "🤣", "😊", "😍", "🥰", "😘", "😎", "🤩", "🥳", "😮", "🥹", "😭",
    "😢", "😡", "🤯", "🥶", "😴", "🤔", "🙃", "😇", "🤪", "😬", "🫠", "🤗",
    "👍", "👎", "👏", "🙌", "🤝", "✌️", "🤘", "🤙", "💪", "🙏", "👀", "💋",
    "🔥", "✨", "⭐️", "🌈", "🎉", "🎈", "💯", "💥", "💫", "🌸", "🍕", "🏆",
]

struct InboxView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: InboxTab = .received
    @State private var received: [DisplayDrawing] = []
    @State private var sent: [SentMessage] = []
    @State private var peek: InboxEntry?
    @State private var detent: PresentationDetent = .large
    @State private var showNotifPriming = false
    @State private var balloons: [Balloon] = []
    @State private var scrollTarget: String?   // entry id a notification tap wants visible
    @Namespace private var tabPill

    init() {
#if DEBUG
        if AppStoreCapture.scene == .reactions {
            _tab = State(initialValue: .sent)
        }
#endif
    }

    var body: some View {
        ZStack {
            Palette.screenBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                tabBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                if shouldShowNotificationNudge {
                    notifNudge
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                feed
            }
            if let peek { peekOverlay(peek) }
            balloonLayer
        }
        // The space chip taps report their position in, and the space the balloons fly
        // in — hoisted above the ScrollView so the flight isn't clipped by the feed.
        .coordinateSpace(name: "inboxSpace")
        .font(DotFont.ui(17))
        .textCase(.lowercase)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.screenBackground)
        .sheet(isPresented: $showNotifPriming) { NotificationPrimingSheet() }
        .onAppear(perform: reload)
        // CloudKit work may finish after this sheet has appeared. The App Group is
        // the source of truth; deliveryRevision tells this snapshot to re-read it.
        .onChange(of: appModel.deliveryRevision) { _, _ in reload() }
        .task { await appModel.notifications.refresh() }   // live status, read fresh
    }

    private var shouldShowNotificationNudge: Bool {
#if DEBUG
        if AppStoreCapture.scene == .reactions { return false }
#endif
        return appModel.notifications.shouldShowFeedNudge
    }

    // MARK: Notification nudge (calm, dismissible; shows only when undecided / denied)

    private var notifNudge: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("turn on notifications").font(DotFont.ui(14, weight: .bold)).foregroundStyle(.white)
                Text("know when a friend draws you something")
                    .font(DotFont.ui(12)).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { nudgeTapped() } label: {
                Text(appModel.notifications.status == .denied ? "settings" : "turn on")
                    .font(DotFont.ui(13, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule(style: .continuous).fill(Theme.cream))
            }
            .buttonStyle(SquishyButtonStyle())
            Button {
                withAnimation(Motion.settle) { appModel.notifications.dismissFeedNudge() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(SquishyButtonStyle())
            .accessibilityLabel("dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Palette.boardBackground)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1))
        )
    }

    private func nudgeTapped() {
        if appModel.notifications.canPrime {
            showNotifPriming = true                         // notDetermined → soft ask
        } else {
            appModel.notifications.openSystemSettings()     // denied → iOS Settings
        }
    }

    private func reload() {
        received = GridStore.shared.receivedHistory()
        sent = GridStore.shared.sentHistory()
        appModel.markInboxSeen()   // opening the inbox clears unread + stops the shimmer
        consumePendingRoute()
    }

    /// Land a tapped notification on its exact target: peek the received drawing,
    /// or switch to sent and scroll to the reacted-to one.
    private func consumePendingRoute() {
        guard let route = appModel.pendingRoute else { return }
        switch route {
        case .receivedDrawing(let senderID, let sentAt):
            tab = .received
            if let drawing = received.first(where: {
                $0.senderID == senderID && abs($0.sentAt.timeIntervalSince(sentAt)) < 1
            }) {
                let entry = InboxEntry(
                    id: "r-\(drawing.senderID)-\(drawing.sentAt.timeIntervalSince1970)",
                    drawing: drawing, token: drawing.token, title: drawing.senderName
                )
                withAnimation(Motion.pop) { peek = entry }
                appModel.pendingRoute = nil
            }
            // If the exact fetch is still in flight, keep the route. The next
            // deliveryRevision reload will resolve it instead of opening an empty
            // inbox and permanently throwing the notification target away.
        case .sentDrawing(let messageID):
            tab = .sent
            scrollTarget = "s-\(messageID)"
            appModel.pendingRoute = nil
        case .friend:
            break   // the friends sheet handles this route
        }
    }

    // MARK: Header + sticky tab

    private var header: some View {
        Text("inbox")
            .font(DotFont.mono(13, bold: true))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .padding(.bottom, 14)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabSegment(.received, "received")
            tabSegment(.sent, "sent")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.boardBackground))
    }

    private func tabSegment(_ target: InboxTab, _ label: String) -> some View {
        let selected = tab == target
        return Button {
            withAnimation(.snappy(duration: 0.25)) { tab = target }
        } label: {
            Text(label)
                .font(DotFont.ui(15, weight: .bold))
                .foregroundStyle(selected ? Theme.ink : .white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.cream)
                            .matchedGeometryEffect(id: "inboxTabPill", in: tabPill)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: Feed (one tab at a time)

    private var entries: [InboxEntry] {
        let mapped: [InboxEntry]
        switch tab {
        case .received:
            mapped = received.map { d in
                InboxEntry(
                    id: "r-\(d.senderID)-\(d.sentAt.timeIntervalSince1970)",
                    drawing: d, token: d.token, title: d.senderName
                )
            }
        case .sent:
            mapped = sent.map { m in
                let token = m.recipients.first?.token ?? m.drawing.token
                let title: String
                if m.recipients.isEmpty {
                    title = "only you"
                } else if m.recipients.count == 1 {
                    title = "to \(m.recipients[0].name)"
                } else {
                    title = "to \(m.recipients[0].name) +\(m.recipients.count - 1)"
                }
                return InboxEntry(id: "s-\(m.id)", drawing: m.drawing, token: token, title: title,
                                  reactions: m.reactions, sendStatus: m.status, messageID: m.id)
            }
        }
        // The feed's ForEach must never see a colliding id: duplicate ids make
        // LazyVStack render ghost copies and cards that blank out mid-scroll.
        // The store heals its own duplicates; this guards any future writer.
        var seen = Set<String>()
        return mapped.filter { seen.insert($0.id).inserted }
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            feedScroll
                .onChange(of: scrollTarget) { _, target in scrollToTarget(target, proxy: proxy) }
                .onAppear { scrollToTarget(scrollTarget, proxy: proxy) }
        }
    }

    /// Give layout a beat, then bring the notification's target card into view.
    private func scrollToTarget(_ target: String?, proxy: ScrollViewProxy) {
        guard let target else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(Motion.settle) { proxy.scrollTo(target, anchor: .center) }
            scrollTarget = nil
        }
    }

    private var feedScroll: some View {
        ScrollView {
            if entries.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 24) {
                    ForEach(entries) { entry in
                        // Received cards tap to peek and carry the reaction tray;
                        // sent cards don't expand — the sent feed is scroll-only.
                        FeedCard(
                            entry: entry,
                            onTap: tab == .received
                                ? { withAnimation(Motion.pop) { peek = entry } }
                                : nil,
                            onReact: tab == .received
                                ? { emoji, point in
                                    let isSetting = entry.drawing.myReaction != emoji
                                    appModel.react(with: emoji, to: entry.drawing)
                                    received = GridStore.shared.receivedHistory()
                                    if isSetting && !reduceMotion { spawnBalloons(emoji, at: point) }
                                }
                                : nil,
                            onResend: entry.messageID.map { id in
                                {
                                    appModel.resendMessage(id: id)
                                    sent = GridStore.shared.sentHistory()
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 36)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(tab == .received
                 ? "no dotdots yet\nwhen a friend sends you one,\nit lands right here"
                 : "nothing sent yet\nmake a dotdot and\nsend it to a friend")
                .font(DotFont.mono(12, bold: true))
                .tracking(1)
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    // MARK: Peek (tap to enlarge)

    private func peekOverlay(_ entry: InboxEntry) -> some View {
        ZStack {
            Color.black.opacity(0.8)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(Motion.settle) { peek = nil } }
                .accessibilityLabel("close")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { withAnimation(Motion.settle) { peek = nil } }
                .transition(.opacity)
            VStack(spacing: 18) {
                DotdotView(drawing: entry.drawing)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    )
                    .frame(maxWidth: 330)
                HStack(spacing: 10) {
                    TokenBadge(token: entry.token, size: 30)
                    Text(entry.title)
                        .font(DotFont.ui(17, weight: .bold))
                        .foregroundStyle(.white)
                    Text("·").foregroundStyle(.white.opacity(0.35))
                    Text(shortRelative(entry.drawing.sentAt))
                        .font(DotFont.mono(13, bold: true))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(28)
            // Pops from a near-full scale (never from nothing) so it reads as the
            // tapped dotdot stepping forward rather than blinking into place.
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }

    // MARK: Balloons — a rare, celebratory moment, so a little delight is earned.
    // They rise at full opacity all the way past the top of the frame (no fade —
    // like balloons escaping), on transform only; never block touches; skipped
    // under Reduce Motion. Speed is constant-ish, so duration scales with distance.

    fileprivate struct Balloon: Identifiable {
        let id = UUID()
        let emoji: String
        let start: CGPoint     // tap point, in "inboxSpace"
        let dx: CGFloat        // sideways drift
        let rotate: Double
        let scale: CGFloat
        let duration: Double
        let delay: Double
    }

    private func spawnBalloons(_ emoji: String, at point: CGPoint) {
        let fresh = (0..<5).map { i -> Balloon in
            let distance = point.y + 90   // to just past the top edge
            return Balloon(emoji: emoji, start: point,
                           dx: CGFloat.random(in: -50...50),
                           rotate: Double.random(in: -22...22),
                           scale: CGFloat.random(in: 0.8...1.3),
                           duration: Double(distance) / Double.random(in: 420...560),
                           delay: Double(i) * 0.06)
        }
        balloons.append(contentsOf: fresh)
        let ids = Set(fresh.map(\.id))
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            balloons.removeAll { ids.contains($0.id) }
        }
    }

    private var balloonLayer: some View {
        ZStack {
            ForEach(balloons) { balloon in
                FloatingEmoji(balloon: balloon)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private struct FloatingEmoji: View {
        let balloon: Balloon
        @State private var up = false

        var body: some View {
            Text(balloon.emoji)
                .font(.system(size: 22))
                .scaleEffect(balloon.scale)
                .rotationEffect(.degrees(up ? balloon.rotate : 0))
                .position(balloon.start)
                .offset(x: up ? balloon.dx : 0,
                        y: up ? -(balloon.start.y + 90) : 0)   // exits past the top frame
                .onAppear {
                    withAnimation(.easeOut(duration: balloon.duration).delay(balloon.delay)) {
                        up = true
                    }
                }
        }
    }
}

// MARK: - Feed card

private struct FeedCard: View {
    let entry: InboxEntry
    /// Tap-to-peek handler. `nil` (the sent feed) leaves the card non-interactive.
    var onTap: (() -> Void)? = nil
    /// React handler (emoji + tap point in "inboxSpace") — present only on the
    /// received feed; shows the emoji tray.
    var onReact: ((String, CGPoint) -> Void)? = nil
    /// Resend handler — sent feed only; shown when the send gave up.
    var onResend: (() -> Void)? = nil

    /// The save chip's lifecycle. Denied sticks (tap routes to Settings);
    /// saved/failed flash their icon, then settle back to idle.
    private enum SaveState { case idle, saving, saved, denied, failed }
    @State private var saveState: SaveState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                DotdotView(drawing: entry.drawing)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )
                TokenBadge(token: entry.token, size: 34)
                    .padding(14)
            }
            .overlay(alignment: .bottomTrailing) {
                saveChip.padding(14)
            }
            HStack(spacing: 8) {
                Text(entry.title)
                    .font(DotFont.ui(16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text(shortRelative(entry.drawing.sentAt))
                    .font(DotFont.mono(12, bold: true))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 4)
            if let onReact {
                ReactionTray(myReaction: entry.drawing.myReaction, onReact: onReact)
                    .padding(.horizontal, 2)
            }
            if !entry.reactions.isEmpty {
                reactionChips
                    .padding(.horizontal, 2)
            }
            statusLine
                .padding(.horizontal, 4)
        }
        .onTapIfPresent(onTap)
    }

    /// Save-to-gallery, tucked on the artwork like the widget's reaction sticker.
    /// Feedback stays on the chip itself (icon flips) — toasts host behind sheets,
    /// so they can't be used here.
    private var saveChip: some View {
        Button {
            switch saveState {
            case .idle, .failed:
                saveState = .saving
                Task {
                    switch await DotdotExporter.save(entry.drawing) {
                    case .saved:
                        saveState = .saved
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        try? await Task.sleep(for: .seconds(1.6))
                        if saveState == .saved { saveState = .idle }
                    case .denied:
                        saveState = .denied
                    case .failed:
                        saveState = .failed
                        try? await Task.sleep(for: .seconds(1.6))
                        if saveState == .failed { saveState = .idle }
                    }
                }
            case .denied:
                // The one state a retry can't fix from here.
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            case .saving, .saved:
                break
            }
        } label: {
            Image(systemName: saveIcon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.black.opacity(0.45)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(SquishyButtonStyle())
        .animation(Motion.crisp(0.2), value: saveState)
        .accessibilityLabel(saveAccessibilityLabel)
    }

    private var saveIcon: String {
        switch saveState {
        case .idle: "square.and.arrow.down"
        case .saving: "ellipsis"
        case .saved: "checkmark"
        case .denied: "lock"
        case .failed: "xmark"
        }
    }

    private var saveAccessibilityLabel: String {
        switch saveState {
        case .idle, .saving: "save to photos"
        case .saved: "saved"
        case .denied: "allow photo access in settings"
        case .failed: "couldn't save"
        }
    }

    /// The honest delivery state under a sent card. Quiet when all is well;
    /// a resend appears only when the send gave up. Local-only shows nothing.
    @ViewBuilder
    private var statusLine: some View {
        switch entry.sendStatus {
        case .sending:
            Text("sending…")
                .font(DotFont.mono(11, bold: true))
                .foregroundStyle(.white.opacity(0.45))
        case .sent:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                Text("sent")
                    .font(DotFont.mono(11, bold: true))
            }
            .foregroundStyle(.white.opacity(0.35))
        case .failed:
            HStack(spacing: 8) {
                Text("not sent yet")
                    .font(DotFont.mono(11, bold: true))
                    .foregroundStyle(Theme.red.opacity(0.9))
                if let onResend {
                    Button(action: onResend) {
                        Text("resend")
                            .font(DotFont.ui(12, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule(style: .continuous).fill(Theme.cream))
                    }
                    .buttonStyle(SquishyButtonStyle())
                    .accessibilityLabel("resend")
                }
                Spacer(minLength: 0)
            }
        case .localOnly, nil:
            EmptyView()
        }
    }

    /// Sent feed: who reacted with what — "❤️ aditya" chips.
    private var reactionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(entry.reactions) { r in
                    HStack(spacing: 5) {
                        Text(r.emoji).font(.system(size: 14))
                        Text(r.reactorName)
                            .font(DotFont.ui(12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(Palette.boardBackground))
                }
            }
        }
    }
}

// MARK: - Reaction tray (received feed)

/// The quick-react row under a received dotdot: five picks + "+" for the full grid.
/// Tapping sets (or, on your current pick, clears) your one reaction. Each chip
/// reports its tap point (in "inboxSpace") so the balloons launch from the finger.
private struct ReactionTray: View {
    let myReaction: String?
    var onReact: (String, CGPoint) -> Void

    @State private var showAll = false
    @State private var plusCenter: CGPoint = .zero   // where sheet picks launch from

    private let haptic = UIImpactFeedbackGenerator(style: .soft)

    var body: some View {
        HStack(spacing: 6) {
            ForEach(quickReactions, id: \.self) { emoji in
                chip(emoji)
            }
            plusChip
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showAll) {
            EmojiPickerSheet { emoji in fire(emoji, at: plusCenter) }
        }
    }

    private func chip(_ emoji: String) -> some View {
        let selected = myReaction == emoji
        return GeometryReader { geo in
            Button { fire(emoji, at: center(of: geo)) } label: {
                Text(emoji)
                    .font(.system(size: 20))
                    .scaleEffect(selected ? 1.0 : 0.9)
                    .frame(width: 46, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(selected ? Theme.cream : Palette.boardBackground)
                    )
            }
            .buttonStyle(SquishyButtonStyle())
            .accessibilityLabel("react with \(emoji)")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .frame(width: 46, height: 40)
        .animation(.snappy(duration: 0.2), value: selected)
    }

    /// If your reaction isn't a quick pick (chosen from the grid), it lives on the
    /// "+" chip so your current pick is always visible somewhere in the tray.
    private var plusChip: some View {
        let offGridPick = myReaction.flatMap { quickReactions.contains($0) ? nil : $0 }
        return GeometryReader { geo in
            Button {
                plusCenter = center(of: geo)   // sheet picks burst from here
                showAll = true
            } label: {
                Group {
                    if let offGridPick {
                        Text(offGridPick).font(.system(size: 20))
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 46, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(offGridPick != nil ? Theme.cream : Palette.boardBackground)
                )
            }
            .buttonStyle(SquishyButtonStyle())
            .accessibilityLabel("more emojis")
        }
        .frame(width: 46, height: 40)
    }

    private func center(of geo: GeometryProxy) -> CGPoint {
        let frame = geo.frame(in: .named("inboxSpace"))
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func fire(_ emoji: String, at point: CGPoint) {
        haptic.impactOccurred(intensity: myReaction != emoji ? 0.7 : 0.4)
        haptic.prepare()
        onReact(emoji, point)
    }
}

// MARK: - Full emoji grid (bottom sheet)

private struct EmojiPickerSheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Palette.screenBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                Text("react with…")
                    .font(DotFont.mono(13, bold: true))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 22)
                    .padding(.bottom, 14)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 6) {
                        ForEach(allReactions, id: \.self) { emoji in
                            Button {
                                onPick(emoji)
                                dismiss()
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 30))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 52)
                            }
                            .buttonStyle(SquishyButtonStyle())
                            .accessibilityLabel("react with \(emoji)")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.screenBackground)
    }
}

private extension View {
    /// Attaches a tap handler only when one is provided; otherwise the view stays
    /// non-interactive (no tap target), so the sent feed has no dead "expand" zone.
    @ViewBuilder
    func onTapIfPresent(_ action: (() -> Void)?) -> some View {
        if let action {
            contentShape(Rectangle()).onTapGesture(perform: action)
        } else {
            self
        }
    }
}

// MARK: - Dotdot render (dots / photo / doodle)

/// Renders a `DisplayDrawing` into a square, mirroring the widget: dots inset on the
/// panel, photos fill, doodles fit. Used by both the feed cards and the peek.
private struct DotdotView: View {
    let drawing: DisplayDrawing

    var body: some View {
        ZStack {
            Theme.panel
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch drawing.kind {
        case .dots:
            GeometryReader { proxy in
                GridBoardView(grid: drawing.grid ?? .empty, spacing: 4)
                    .padding(proxy.size.width * 0.07)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        case .photo:
            if let data = drawing.imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                placeholder
            }
        case .doodle:
            if let data = drawing.imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white.opacity(0.35))
    }
}

// MARK: - Helpers

/// Compact, lowercase relative time: "now", "5m", "3h", "2d", else "jul 4".
private func shortRelative(_ date: Date) -> String {
    let seconds = max(0, Date().timeIntervalSince(date))
    switch seconds {
    case ..<60:            return "now"
    case ..<3600:          return "\(Int(seconds / 60))m"
    case ..<86_400:        return "\(Int(seconds / 3600))h"
    case ..<(7 * 86_400):  return "\(Int(seconds / 86_400))d"
    default:
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date).lowercased()
    }
}
