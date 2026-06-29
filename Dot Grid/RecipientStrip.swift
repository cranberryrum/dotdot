//
//  RecipientStrip.swift
//  Dot Grid
//
//  The inline "send to" row that sits just above the send button in every composer.
//  Pick recipients without leaving the canvas: "everyone" first, then each friend as
//  a tappable avatar with their name below. Selection lives on AppModel, so it's
//  shared across all three modes and gates the send button. Shown only when you have
//  friends — with none, sending falls back to a local-only echo (unchanged).
//

import SwiftUI
import UIKit

/// Which "send to" UI the composers use.
///
/// We currently ship the **sheet** flow (tap send → `RecipientPickerView`). The
/// no-friction **inline** flow — this strip of avatars above the send button — is
/// kept fully wired and one flip away: set `useInlineRecipients = true` to bring it
/// back across all three composers. Nothing else needs to change.
enum SendFlow {
    static let useInlineRecipients = false
}

struct RecipientStrip: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let avatar: CGFloat = 50
    private static let ringGap: CGFloat = 8   // how far the selected ring sits outside
    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                everyoneChip
                ForEach(appModel.friends) { friend in
                    friendChip(friend)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .onAppear {
            appModel.seedRecipientSelectionIfNeeded()
            tapHaptic.prepare()
        }
    }

    // MARK: Chips

    /// "everyone" — a cream group circle that selects/clears the whole roster.
    private var everyoneChip: some View {
        chip(selected: appModel.isAllRecipientsSelected, name: "everyone") {
            tap { appModel.toggleAllRecipients() }
        } avatar: {
            ZStack {
                Circle().fill(Theme.cream)
                Image(systemName: "person.2.fill")
                    .font(.system(size: Self.avatar * 0.42, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.85))
            }
        }
    }

    private func friendChip(_ friend: FriendInfo) -> some View {
        chip(selected: appModel.selectedRecipientIDs.contains(friend.id), name: friend.name) {
            tap { appModel.toggleRecipient(friend.id) }
        } avatar: {
            TokenBadge(token: friend.token, size: Self.avatar)
        }
    }

    /// One avatar + name, with a clean selected state: full-brightness, a white ring
    /// just outside the circle, a little corner check, and a subtle scale-up. The
    /// unselected state dims and shrinks a touch — the same language as the color
    /// swatches, so picking a recipient reads exactly like picking a color.
    @ViewBuilder
    private func chip<Avatar: View>(
        selected: Bool,
        name: String,
        action: @escaping () -> Void,
        @ViewBuilder avatar: () -> Avatar
    ) -> some View {
        let ringSide = Self.avatar + Self.ringGap
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    avatar()
                        .frame(width: Self.avatar, height: Self.avatar)
                    Circle()
                        .strokeBorder(.white.opacity(selected ? 0.95 : 0), lineWidth: 3)
                        .frame(width: ringSide, height: ringSide)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 19, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.ink, .white)
                            .offset(x: Self.avatar * 0.34, y: Self.avatar * 0.34)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .frame(width: ringSide, height: ringSide)
                .scaleEffect(selected ? 1 : 0.9)
                .opacity(selected ? 1 : 0.55)

                Text(name)
                    .font(DotFont.ui(12, weight: selected ? .bold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.4))
                    .lineLimit(1)
                    .frame(maxWidth: ringSide + 10)
            }
        }
        .buttonStyle(SquishyButtonStyle())
        .animation(
            reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.72),
            value: selected
        )
    }

    private func tap(_ change: () -> Void) {
        tapHaptic.impactOccurred(intensity: 0.7)
        tapHaptic.prepare()
        change()
    }
}
