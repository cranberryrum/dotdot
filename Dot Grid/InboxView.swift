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
}

struct InboxView: View {
    @Environment(AppModel.self) private var appModel
    @State private var tab: InboxTab = .received
    @State private var received: [DisplayDrawing] = []
    @State private var sent: [SentMessage] = []
    @State private var peek: InboxEntry?
    @State private var detent: PresentationDetent = .large
    @State private var showNotifPriming = false
    @Namespace private var tabPill

    var body: some View {
        ZStack {
            Palette.screenBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                tabBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                if appModel.notifications.shouldShowFeedNudge {
                    notifNudge
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                feed
            }
            if let peek { peekOverlay(peek) }
        }
        .font(DotFont.ui(17))
        .textCase(.lowercase)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.screenBackground)
        .sheet(isPresented: $showNotifPriming) { NotificationPrimingSheet() }
        .onAppear(perform: reload)
        .task { await appModel.notifications.refresh() }   // live status, read fresh
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
    }

    // MARK: Feed (one tab at a time)

    private var entries: [InboxEntry] {
        switch tab {
        case .received:
            return received.map { d in
                InboxEntry(
                    id: "r-\(d.senderID)-\(d.sentAt.timeIntervalSince1970)",
                    drawing: d, token: d.token, title: d.senderName
                )
            }
        case .sent:
            return sent.map { m in
                let token = m.recipients.first?.token ?? m.drawing.token
                let title: String
                if m.recipients.isEmpty {
                    title = "only you"
                } else if m.recipients.count == 1 {
                    title = "to \(m.recipients[0].name)"
                } else {
                    title = "to \(m.recipients[0].name) +\(m.recipients.count - 1)"
                }
                return InboxEntry(id: "s-\(m.id)", drawing: m.drawing, token: token, title: title)
            }
        }
    }

    private var feed: some View {
        ScrollView {
            if entries.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 24) {
                    ForEach(entries) { entry in
                        // Received cards tap to peek; sent cards don't expand — the
                        // sent feed is scroll-only.
                        FeedCard(entry: entry, onTap: tab == .received
                                 ? { withAnimation(Motion.pop) { peek = entry } }
                                 : nil)
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
}

// MARK: - Feed card

private struct FeedCard: View {
    let entry: InboxEntry
    /// Tap-to-peek handler. `nil` (the sent feed) leaves the card non-interactive.
    var onTap: (() -> Void)? = nil

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
        }
        .onTapIfPresent(onTap)
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
