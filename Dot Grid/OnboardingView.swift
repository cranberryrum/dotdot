//
//  OnboardingView.swift
//  Dot Grid
//
//  Routes the persisted first-run state through focused, resumable steps.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Palette.screenBackground
                .ignoresSafeArea()
            HalftoneField(color: .white.opacity(0.035))
                .ignoresSafeArea()

            stepView
                .id(appModel.onboardingProgress.step)
                .transition(.opacity)
        }
        .animation(reduceMotion ? Motion.reduced : Motion.crisp(0.22), value: appModel.onboardingProgress.step)
        .font(DotFont.ui(17))
        .textCase(.lowercase)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var stepView: some View {
        switch appModel.onboardingProgress.step {
        case .introduction:
            OnboardingIntroView {
                appModel.advanceOnboarding(.finishedIntroduction)
            }
        case .modes:
            OnboardingModesView {
                appModel.advanceOnboarding(.finishedModes)
            }
        case .identity:
            OnboardingIdentityView()
        case .connection:
            AddFriendView { outcome in
                appModel.advanceOnboarding(outcome == .connected ? .connectedFriend : .choseSolo)
            }
        case .widget:
            OnboardingWidgetView(
                onFinished: { appModel.advanceOnboarding(.finishedWidgetEducation) },
                onSkipped: { appModel.advanceOnboarding(.skippedWidgetEducation) }
            )
        case .complete:
            // Completion normally changes AppModel.phase in the same transaction.
            // This bridge prevents a blank frame if SwiftUI renders once in between.
            ComposerView()
        }
    }
}
