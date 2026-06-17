//
//  RootView.swift
//  Dot Grid
//
//  Routes between loading, onboarding, and the composer, and owns app lifecycle
//  hooks (foreground refresh, invite links, transient banner).
//

import SwiftUI

struct RootView: View {
    @State private var appModel = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch appModel.phase {
            case .loading:
                loading
            case .onboarding:
                OnboardingView()
            case .ready, .iCloudUnavailable:
                ContentView()
            }
        }
        .environment(appModel)
        .animation(.easeInOut(duration: 0.25), value: appModel.phase)
        .task { appModel.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await appModel.onForeground() } }
        }
        .onOpenURL { appModel.handleInviteURL($0) }
        .overlay(alignment: .top) { bannerOverlay }
    }

    private var loading: some View {
        ZStack {
            Palette.screenBackground.ignoresSafeArea()
            ProgressView().tint(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var bannerOverlay: some View {
        if let text = appModel.banner {
            Text(text)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Capsule().fill(Color(red: 0.16, green: 0.16, blue: 0.20)).shadow(color: .black.opacity(0.4), radius: 12, y: 4))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { appModel.banner = nil }
                }
        }
    }
}
