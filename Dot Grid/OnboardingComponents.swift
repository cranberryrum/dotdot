//
//  OnboardingComponents.swift
//  Dot Grid
//
//  Small pieces shared by the focused onboarding steps.
//

import SwiftUI

struct OnboardingPrimaryButton: View {
    let title: String
    var color: Color = Theme.cream
    var prefersDarkText = true
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DotFont.heavy(18))
                .foregroundStyle(prefersDarkText ? Theme.ink : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(color)
                )
                .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(disabled)
    }
}

struct OnboardingHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(DotFont.heavy(28))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(DotFont.ui(15))
                    .foregroundStyle(.white.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingWidgetPreview: View {
    var grid: Grid = .onboardingSmile
    var senderName = "maya"
    var senderToken = IdentityToken(symbol: "M", colorIndex: 1)
    var showsSender = true

    var body: some View {
        VStack(spacing: 8) {
            GridBoardView(grid: grid, spacing: 3)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Palette.boardBackground)
                )

            if showsSender {
                HStack(spacing: 7) {
                    TokenBadge(token: senderToken, size: 24)
                    Text("from \(senderName)")
                        .font(DotFont.ui(12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.62))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("home screen widget preview, a tiny dot drawing from \(senderName)")
    }
}

extension Grid {
    static let onboardingSmile: Grid = {
        let art = [
            "........",
            "..X..X..",
            "..X..X..",
            "........",
            ".X....X.",
            "..XXXX..",
            "........",
            "........",
        ]
        return grid(from: art, colorIndex: 4)
    }()

    static let onboardingWave: Grid = {
        let art = [
            "........",
            ".X......",
            "..X.....",
            "...X..X.",
            "....XX..",
            "........",
            "........",
            "........",
        ]
        return grid(from: art, colorIndex: 5)
    }()

    private static func grid(from art: [String], colorIndex: Int) -> Grid {
        var grid = Grid.empty(side: 8)
        for (row, line) in art.enumerated() {
            for (column, character) in line.enumerated() where character == "X" {
                grid[row, column] = Cell(colorIndex: colorIndex, size: .medium)
            }
        }
        return grid
    }
}
