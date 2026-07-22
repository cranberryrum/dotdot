//
//  OnboardingModesView.swift
//  Dot Grid
//
//  One interactive explanation of the three real composer modes.
//

import SwiftUI

struct OnboardingModesView: View {
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: ComposeMode = .dots
    @State private var dotGrid = Grid.empty
    @State private var doodleProgress: CGFloat = 0

    private var copy: String {
        switch mode {
        case .dots: "tap out a tiny pixel message."
        case .photo: "send the moment as it happened."
        case .doodle: "scribble it in your own hand."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader(title: "three ways to say hi.")
                .padding(.top, 28)
                .padding(.horizontal, 20)

            ComposeModePicker(selection: $mode)
                .padding(.horizontal, 20)
                .padding(.top, 22)

            Spacer(minLength: 12)

            preview
                .frame(maxWidth: .infinity)
                .frame(height: 280)
                .id(mode)
                .transition(.opacity)

            Text(copy)
                .font(DotFont.ui(17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .padding(.horizontal, 24)
                .accessibilityLabel(copy)

            Spacer(minLength: 16)

            OnboardingPrimaryButton(title: "make dotdot mine", action: onContinue)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .animation(reduceMotion ? Motion.reduced : Motion.crisp(0.2), value: mode)
        .task(id: mode) { await animatePreview() }
    }

    @ViewBuilder
    private var preview: some View {
        switch mode {
        case .dots:
            GridBoardView(grid: dotGrid, spacing: 5)
                .frame(width: 218, height: 218)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Palette.boardBackground)
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("animated dot grid smile")
        case .photo:
            photoPreview
        case .doodle:
            doodlePreview
        }
    }

    private var photoPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Palette.boardBackground)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.peri.opacity(0.58))
                .padding(14)
            Circle()
                .fill(Theme.yellow)
                .frame(width: 38, height: 38)
                .offset(x: 62, y: -62)
            DoodleHillShape()
                .fill(Theme.ink.opacity(0.78))
                .padding(14)
            HStack(spacing: 7) {
                Image(systemName: "camera.fill")
                Text("a moment")
            }
            .font(DotFont.ui(13, weight: .bold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(Theme.cream))
            .offset(y: 72)
        }
        .frame(width: 250, height: 250)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("photo mode preview, no camera is active")
    }

    private var doodlePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Palette.boardBackground)
            DoodleHeartShape()
                .trim(from: 0, to: reduceMotion ? 1 : doodleProgress)
                .stroke(
                    Theme.pink,
                    style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
                )
                .padding(42)
            DoodleUnderlineShape()
                .trim(from: 0, to: reduceMotion ? 1 : doodleProgress)
                .stroke(
                    Theme.lime,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
                )
                .padding(54)
        }
        .frame(width: 250, height: 250)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("hand-drawn heart doodle")
    }

    @MainActor
    private func animatePreview() async {
        switch mode {
        case .dots:
            dotGrid = .empty
            let sample = Grid.onboardingSmile
            for index in sample.cells.indices where sample.cells[index] != nil {
                guard !Task.isCancelled, mode == .dots else { return }
                withAnimation(Motion.place(reduceMotion: reduceMotion)) {
                    dotGrid.cells[index] = sample.cells[index]
                }
                try? await Task.sleep(for: .seconds(0.035))
            }
        case .photo:
            break
        case .doodle:
            doodleProgress = reduceMotion ? 1 : 0
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.55)) { doodleProgress = 1 }
        }
    }
}

private struct DoodleHillShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.64))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.56, y: rect.height * 0.58),
            control1: CGPoint(x: rect.width * 0.18, y: rect.height * 0.45),
            control2: CGPoint(x: rect.width * 0.32, y: rect.height * 0.76)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * 0.42),
            control1: CGPoint(x: rect.width * 0.72, y: rect.height * 0.42),
            control2: CGPoint(x: rect.width * 0.84, y: rect.height * 0.38)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct DoodleHeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY * 0.86))
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.height * 0.38),
            control1: CGPoint(x: rect.width * 0.32, y: rect.height * 0.70),
            control2: CGPoint(x: rect.width * 0.08, y: rect.height * 0.62)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.height * 0.28),
            control1: CGPoint(x: rect.width * 0.10, y: rect.height * 0.12),
            control2: CGPoint(x: rect.width * 0.40, y: rect.height * 0.12)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.10, y: rect.height * 0.40),
            control1: CGPoint(x: rect.width * 0.62, y: rect.height * 0.10),
            control2: CGPoint(x: rect.width * 0.90, y: rect.height * 0.14)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY * 0.86),
            control1: CGPoint(x: rect.width * 0.92, y: rect.height * 0.62),
            control2: CGPoint(x: rect.width * 0.70, y: rect.height * 0.72)
        )
        return path
    }
}

private struct DoodleUnderlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.84))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * 0.80),
            control1: CGPoint(x: rect.width * 0.30, y: rect.height * 0.95),
            control2: CGPoint(x: rect.width * 0.66, y: rect.height * 0.68)
        )
        return path
    }
}
