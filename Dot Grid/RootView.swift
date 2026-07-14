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
                ComposerView()
            }
        }
        .environment(appModel)
        .animation(.easeInOut(duration: 0.25), value: appModel.phase)
        .task { appModel.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await appModel.onForeground() } }
            if phase == .background { appModel.onBackground() }   // hand sends to BG refresh
        }
        .overlay(alignment: .top) { toastOverlay }
    }

    private var loading: some View {
        ZStack {
            Palette.screenBackground.ignoresSafeArea()
            ProgressView().tint(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = appModel.toast {
            ToastView(
                toast: toast,
                onAction: { appModel.runToastAction() },
                onDismiss: { appModel.dismissToast() }
            )
            .id(toast.id)
        }
    }
}
