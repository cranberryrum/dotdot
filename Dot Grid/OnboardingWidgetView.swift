//
//  OnboardingWidgetView.swift
//  Dot Grid
//
//  Optional widget education; installing one is never a completion gate.
//

import SwiftUI

struct OnboardingWidgetView: View {
    let onFinished: () -> Void
    let onSkipped: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsInstructions = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader(
                title: "put dotdot where you’ll see it.",
                subtitle: "your widget is where new dotdots from friends land."
            )
            .padding(.horizontal, 24)
            .padding(.top, 30)

            Spacer(minLength: 18)

            if showsInstructions {
                instructions
                    .transition(.opacity)
            } else {
                OnboardingWidgetPreview(grid: .onboardingWave)
                    .frame(width: 224)
                    .transition(.opacity)
            }

            Spacer(minLength: 20)

            VStack(spacing: 6) {
                OnboardingPrimaryButton(
                    title: showsInstructions ? "start drawing" : "show me how",
                    action: showsInstructions ? onFinished : showInstructions
                )

                Button("i’ll do it later", action: onSkipped)
                    .font(DotFont.ui(16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                    .buttonStyle(SquishyButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 18) {
            instruction(1, "touch and hold an empty spot on your home screen.")
            instruction(2, "tap edit, then add widget.")
            instruction(3, "search for dotdot and pick the size you like.")
        }
        .padding(22)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Palette.boardBackground)
        )
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
    }

    private func instruction(_ number: Int, _ copy: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text("\(number)")
                .font(DotFont.mono(13, bold: true))
                .foregroundStyle(Theme.ink)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.color(at: number + 1)))
            Text(copy)
                .font(DotFont.ui(16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func showInstructions() {
        withAnimation(reduceMotion ? Motion.reduced : Motion.surface) {
            showsInstructions = true
        }
    }
}
