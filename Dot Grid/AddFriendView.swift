//
//  AddFriendView.swift
//  Dot Grid
//
//  Pairing is code-only, no approval: type a friend's one-time code, or share
//  your own copyable code. No links.
//

import SwiftUI
import UIKit

struct AddFriendView: View {
    @Environment(AppModel.self) private var appModel

    /// Called when used inside onboarding ("Done"). Nil when shown as a sheet.
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var codeEntry = ""
    @State private var connecting = false
    @State private var resultText: String?
    @State private var resultIsError = false

    @State private var myCode: String?
    @State private var generating = false
    @State private var copied = false
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                enterCodeCard
                shareCard

                if let resultText {
                    Text(resultText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(resultIsError ? .red.opacity(0.9) : .green.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                Button {
                    onDone?() ?? dismiss()
                } label: {
                    Text(onDone == nil ? "Done" : "Continue to drawing")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.boardBackground))
                }
                .buttonStyle(SquishyButtonStyle())
            }
            .padding(20)
        }
        .background(Palette.screenBackground.ignoresSafeArea())
        .font(DotFont.ui(17))
        .textCase(.lowercase)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("add a friend")
                .font(DotFont.heavy(22))
                .foregroundStyle(.white)
            Text("Pairing is instant — no requests to approve.")
                .font(DotFont.ui(14))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.top, 8)
    }

    // MARK: Enter a code

    private var enterCodeCard: some View {
        card {
            Text("enter a code")
                .font(DotFont.heavy(15)).foregroundStyle(.white)
            TextField("", text: $codeEntry, prompt: Text("6-digit code").foregroundStyle(.white.opacity(0.4)))
                .keyboardType(.numberPad)
                .font(DotFont.mono(28, bold: true))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
                .onChange(of: codeEntry) { _, new in
                    codeEntry = String(new.filter(\.isNumber).prefix(6))
                }
            Button {
                Task { await connect() }
            } label: {
                Text(connecting ? "Connecting…" : "Connect")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(codeEntry.count != 6 || connecting)
            .opacity(codeEntry.count != 6 ? 0.5 : 1)
        }
    }

    private func connect() async {
        connecting = true
        withAnimation { resultText = nil }
        do {
            try await appModel.addFriend(byCode: codeEntry)
            withAnimation { resultText = "Connected! 🎉"; resultIsError = false }
            codeEntry = ""
        } catch {
            withAnimation {
                resultText = (error as? PairingError)?.errorDescription ?? "Couldn't connect."
                resultIsError = true
            }
        }
        connecting = false
    }

    // MARK: Your code

    private var shareCard: some View {
        card {
            Text("your code")
                .font(DotFont.heavy(15)).foregroundStyle(.white)
            Text("Share this with a friend so they can add you.")
                .font(DotFont.ui(13)).foregroundStyle(.white.opacity(0.5))

            if let myCode {
                HStack(spacing: 12) {
                    Text(myCode)
                        .font(DotFont.mono(38, bold: true))
                        .tracking(6)
                        .foregroundStyle(Theme.lime)
                    Spacer()
                    Button { copy(myCode) } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc.fill")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.black.opacity(0.85))
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(.white))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(SquishyButtonStyle())
                }
                Text("Single-use · expires in 10 minutes")
                    .font(DotFont.mono(11)).foregroundStyle(.white.opacity(0.5))
            }

            Button {
                Task { await makeCode() }
            } label: {
                Text(generating ? "Generating…" : (myCode == nil ? "Get a code" : "Get a new code"))
                    .font(DotFont.ui(15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.08)))
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(generating)
        }
    }

    private func copy(_ code: String) {
        UIPasteboard.general.string = code
        withAnimation { copied = true }
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation { copied = false }
        }
    }

    private func makeCode() async {
        generating = true
        copied = false
        do { myCode = try await appModel.generateCode() }
        catch { withAnimation { resultText = (error as? PairingError)?.errorDescription ?? "Couldn't make a code."; resultIsError = true } }
        generating = false
    }

    // MARK: Card chrome

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.boardBackground))
    }
}
