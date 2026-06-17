//
//  OnboardingView.swift
//  Dot Grid
//
//  First run: pick a name and an identity token, then optionally add a friend.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel

    @State private var step = 1
    @State private var name = ""
    @State private var symbol = "★"
    @State private var colorIndex = 0
    @State private var working = false
    @State private var errorText: String?

    private let symbols = ["★", "♥", "✦", "☺", "✿", "✚", "◆", "▲", "♪", "✺", "☀", "☆"]

    private var token: IdentityToken { IdentityToken(symbol: symbol, colorIndex: colorIndex) }
    private var symbolOptions: [String] {
        let initial = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() }
        return ([initial].compactMap { $0 } + symbols)
    }

    var body: some View {
        VStack(spacing: 0) {
            if step == 1 { profileStep } else { friendStep }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.screenBackground.ignoresSafeArea())
        .fontDesign(.rounded)
        .preferredColorScheme(.dark)
    }

    // MARK: Step 1 — name + token

    private var profileStep: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 8)

            TokenBadge(token: token, size: 96)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: token)

            VStack(spacing: 6) {
                Text("What's your name?")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("This is how friends see you.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }

            TextField("", text: $name, prompt: Text("Your name").foregroundStyle(.white.opacity(0.4)))
                .textInputAutocapitalization(.words)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.boardBackground))
                .padding(.horizontal, 30)

            VStack(spacing: 14) {
                symbolPicker
                colorPicker
            }

            Spacer()

            Button {
                Task { await advanceFromProfile() }
            } label: {
                primaryLabel(working ? "Saving…" : "Continue")
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
            .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red.opacity(0.9))
                    .padding(.bottom, 8)
            }
        }
        .padding(.top, 40)
    }

    private var symbolPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(symbolOptions, id: \.self) { option in
                    Button { symbol = option } label: {
                        Text(option)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(.white.opacity(symbol == option ? 0.18 : 0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 12) {
            ForEach(Palette.entries.indices, id: \.self) { index in
                Button { colorIndex = index } label: {
                    Circle()
                        .fill(Palette.color(at: index))
                        .frame(width: 38, height: 38)
                        .overlay(Circle().strokeBorder(.white.opacity(colorIndex == index ? 0.95 : 0), lineWidth: 3).padding(3))
                        .scaleEffect(colorIndex == index ? 1 : 0.85)
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: colorIndex)
            }
        }
    }

    private func advanceFromProfile() async {
        working = true; errorText = nil
        do {
            try await appModel.createProfile(name: name.trimmingCharacters(in: .whitespaces), token: token)
            step = 2
        } catch {
            errorText = (error as? PairingError)?.errorDescription ?? "Couldn't save. Try again."
        }
        working = false
    }

    // MARK: Step 2 — add a friend or skip

    private var friendStep: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { appModel.markReady() }
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            AddFriendView(onDone: { appModel.markReady() })
        }
    }

    private func primaryLabel(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.heavy))
            .foregroundStyle(token.prefersDarkText ? Color.black.opacity(0.8) : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(token.color))
    }
}
