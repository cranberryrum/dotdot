//
//  ComposerView.swift
//  Dot Grid
//
//  Hosts the shared top bar and the Dots | Photo mode switch. Both composers stay
//  mounted (toggled by opacity) so each mode keeps its in-progress state while the
//  app is open. The switch is in-app only — there is no home-screen widget swiping.
//

import SwiftUI

enum ComposeMode: String { case dots, photo }

struct ComposerView: View {
    @Environment(AppModel.self) private var appModel

    @AppStorage("composeMode") private var modeRaw = ComposeMode.dots.rawValue
    @State private var showAddFriend = false
    @State private var showDebug = false
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
                    PhotoComposerView()
                        .opacity(mode == .photo ? 1 : 0)
                        .allowsHitTesting(mode == .photo)
                }
            }
            .padding(20)
        }
        .fontDesign(.rounded)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAddFriend) { AddFriendView() }
        .sheet(isPresented: $showDebug) { DebugView() }
    }

    // MARK: Top bar (shared across modes)

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                wordmark
                Spacer()
                if appModel.hasPendingSends {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("\(appModel.outbox.count)")
                    }
                    .font(DotFont.mono(12, bold: true))
                    .foregroundStyle(.white.opacity(0.55))
                }
                if let me = appModel.profile {
                    TokenBadge(token: me.token, size: 32)
                        .onLongPressGesture { showDebug = true }
                }
                Button { showAddFriend = true } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Palette.boardBackground))
                }
                .buttonStyle(SquishyButtonStyle())
            }
            if !appModel.isSignedIn {
                iCloudBanner
            }
        }
    }

    /// The DOTDOT wordmark in Bagel Fat One, two playful colors.
    private var wordmark: some View {
        HStack(spacing: 0) {
            Text("dot").foregroundStyle(Theme.blue)
            Text("dot").foregroundStyle(Theme.pink)
        }
        .font(DotFont.bubble(30))
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
