//
//  OnboardingIntroView.swift
//  Dot Grid
//
//  A short, skippable explanation of the product loop: make, send, land.
//

import SwiftUI
import UIKit

struct OnboardingLaunchBridge: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DotdotWordmark(size: 32, color: Theme.blue)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.screenBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityHidden(true)
    }
}

struct OnboardingIntroView: View {
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawing = Grid.empty
    @State private var storyStage = 0
    @State private var isFinished = false
    @State private var storyTask: Task<Void, Never>?

    private let aliveHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let landingHaptic = UIImpactFeedbackGenerator(style: .medium)

    private var phrase: String {
        switch storyStage {
        case 0: "make something small."
        case 1: "send it to someone."
        default: "right on their home screen."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DotdotWordmark(size: 32, color: Theme.blue)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Spacer(minLength: 16)

            storyVisual
                .frame(height: 260)

            Text(phrase)
                .font(DotFont.heavy(25))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(Motion.crisp(0.18), value: phrase)
                .accessibilityLabel("make something small. send it to someone. right on their home screen.")
                .accessibilityHint(isFinished ? "" : "double tap to skip the animation")
                .accessibilityAction { fastForward() }
                .padding(.horizontal, 24)

            Spacer(minLength: 18)

            OnboardingPrimaryButton(title: "see dotdot in action", action: onContinue)
                .opacity(isFinished ? 1 : 0)
                .offset(y: reduceMotion || isFinished ? 0 : 8)
                .allowsHitTesting(isFinished)
                .accessibilityHidden(!isFinished)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .contentShape(Rectangle())
        .onTapGesture { fastForward() }
        .onAppear { startStory() }
        .onDisappear { storyTask?.cancel() }
    }

    private var storyVisual: some View {
        ZStack {
            OnboardingWidgetPreview(
                grid: storyStage >= 2 ? .onboardingSmile : .empty,
                senderName: "you",
                senderToken: IdentityToken(symbol: "Y", colorIndex: 0)
            )
            .frame(width: 184)
            .opacity(storyStage >= 1 ? 1 : 0)
            .offset(y: reduceMotion ? 0 : 12)

            if storyStage < 2 {
                GridBoardView(grid: drawing, spacing: 4)
                    .frame(width: 126, height: 126)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Palette.boardBackground)
                    )
                    .scaleEffect(reduceMotion ? 1 : (storyStage == 1 ? 0.88 : 1))
                    .rotationEffect(reduceMotion ? .zero : .degrees(storyStage == 1 ? -2 : 0))
                    .offset(y: reduceMotion ? 0 : (storyStage == 1 ? -58 : 0))
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? Motion.reduced : .easeInOut(duration: 0.42), value: storyStage)
        .accessibilityHidden(true)
    }

    private func startStory() {
        aliveHaptic.prepare()
        landingHaptic.prepare()
        storyTask?.cancel()
        storyTask = Task { @MainActor in
            guard await pause(0.10) else { return }
            let sample = Grid.onboardingSmile
            for index in sample.cells.indices where sample.cells[index] != nil {
                guard !Task.isCancelled else { return }
                withAnimation(Motion.place(reduceMotion: reduceMotion)) {
                    drawing.cells[index] = sample.cells[index]
                }
                guard await pause(0.04) else { return }
            }
            aliveHaptic.impactOccurred()
            guard await pause(0.25) else { return }
            withAnimation(reduceMotion ? Motion.reduced : .easeInOut(duration: 0.42)) {
                storyStage = 1
            }
            guard await pause(0.65) else { return }
            withAnimation(reduceMotion ? Motion.reduced : Motion.pop) {
                storyStage = 2
            }
            landingHaptic.impactOccurred()
            guard await pause(0.58) else { return }
            revealCTA()
        }
    }

    private func pause(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func fastForward() {
        guard !isFinished else { return }
        storyTask?.cancel()
        drawing = .onboardingSmile
        withAnimation(reduceMotion ? Motion.reduced : Motion.crisp(0.2)) {
            storyStage = 2
        }
        revealCTA()
    }

    private func revealCTA() {
        withAnimation(reduceMotion ? Motion.reduced : Motion.surface) {
            isFinished = true
        }
    }
}
