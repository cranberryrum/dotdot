//
//  OnboardingIdentityView.swift
//  Dot Grid
//
//  Name and identity token stay together, with a live preview of what friends see.
//

import SwiftUI

struct OnboardingIdentityView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var name = ""
    @State private var symbol = "★"
    @State private var colorIndex = 0
    @State private var choseSymbol = false
    @State private var working = false
    @State private var errorText: String?

    private let symbols = ["★", "♥", "✦", "☺", "✿", "✚", "◆", "▲", "♪", "✺", "☀", "☆"]

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var initial: String? { trimmedName.first.map { String($0).uppercased() } }
    private var token: IdentityToken { IdentityToken(symbol: symbol, colorIndex: colorIndex) }
    private var symbolOptions: [String] {
        let options = [initial].compactMap { $0 } + symbols
        var seen = Set<String>()
        return options.filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                OnboardingHeader(
                    title: "who’s sending?",
                    subtitle: "this little token is how friends will know it’s you."
                )
                .padding(.top, 28)

                tokenPreview

                TextField(
                    "",
                    text: $name,
                    prompt: Text("your name").foregroundStyle(.white.opacity(0.38))
                )
                .textInputAutocapitalization(.words)
                .textContentType(.name)
                .submitLabel(.continue)
                .font(DotFont.ui(20, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .frame(minHeight: 54)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Palette.boardBackground)
                )
                .accessibilityLabel("your name")
                .onSubmit { submit() }
                .onChange(of: name) { _, _ in
                    if !choseSymbol { symbol = initial ?? "★" }
                    if errorText != nil { errorText = nil }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("your symbol").metaLabel()
                        .padding(.horizontal, 2)
                    symbolPicker
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("your color").metaLabel()
                        .padding(.horizontal, 2)
                    colorPicker
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                Button(action: submit) {
                    HStack(spacing: 9) {
                        if working { ProgressView().tint(token.prefersDarkText ? Theme.ink : .white) }
                        Text("that’s me")
                    }
                    .font(DotFont.heavy(18))
                    .foregroundStyle(token.prefersDarkText ? Theme.ink : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(token.color)
                    )
                    .opacity(trimmedName.isEmpty ? 0.5 : 1)
                }
                .buttonStyle(SquishyButtonStyle())
                .disabled(trimmedName.isEmpty || working)

                if let errorText {
                    Text(errorText)
                        .font(DotFont.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.red)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                        .accessibilityLabel("error: \(errorText)")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(Palette.screenBackground.opacity(0.97))
        }
    }

    private var tokenPreview: some View {
        VStack(spacing: 12) {
            TokenBadge(token: token, size: 82)
                .animation(reduceMotion ? Motion.reduced : Motion.dotpop, value: token)

            HStack(spacing: 8) {
                TokenBadge(token: token, size: 28)
                Text("from \(trimmedName.isEmpty ? "you" : trimmedName)")
                    .font(DotFont.ui(14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.leading, 7)
            .padding(.trailing, 12)
            .frame(minHeight: 42)
            .background(Capsule().fill(.white.opacity(0.07)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("friends will see: from \(trimmedName.isEmpty ? "you" : trimmedName), symbol \(symbol), color \(Palette.name(at: colorIndex))")
        }
    }

    private var symbolPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(symbolOptions, id: \.self) { option in
                    Button {
                        choseSymbol = true
                        symbol = option
                    } label: {
                        Text(option)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(.white.opacity(symbol == option ? 0.18 : 0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("symbol \(option)")
                    .accessibilityAddTraits(symbol == option ? .isSelected : [])
                }
            }
        }
    }

    private var colorPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Palette.entries.indices, id: \.self) { index in
                    Button { colorIndex = index } label: {
                        Circle()
                            .fill(Palette.color(at: index))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Circle()
                                    .strokeBorder(.white.opacity(colorIndex == index ? 0.95 : 0), lineWidth: 3)
                                    .padding(3)
                            )
                            .scaleEffect(colorIndex == index ? 1 : 0.86)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .animation(reduceMotion ? Motion.reduced : Motion.settle, value: colorIndex)
                    .accessibilityLabel(Palette.name(at: index))
                    .accessibilityAddTraits(colorIndex == index ? .isSelected : [])
                }
            }
        }
    }

    private func submit() {
        guard !trimmedName.isEmpty, !working else { return }
        Task { await createProfile() }
    }

    @MainActor
    private func createProfile() async {
        working = true
        errorText = nil
        do {
            try await appModel.createProfile(name: trimmedName, token: token)
        } catch {
            withAnimation(Motion.surface) {
                errorText = (error as? PairingError)?.errorDescription ?? "couldn’t save. try again."
            }
        }
        working = false
    }
}
