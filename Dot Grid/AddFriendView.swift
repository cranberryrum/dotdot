//
//  AddFriendView.swift
//  Dot Grid
//
//  Two ways in, no approval: type a friend's one-time code, or share your link.
//

import SwiftUI

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
        .fontDesign(.rounded)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("ADD A FRIEND")
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
            Text("ENTER A CODE")
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

    // MARK: Share your invite

    private var shareCard: some View {
        card {
            Text("SHARE YOUR INVITE")
                .font(DotFont.heavy(15)).foregroundStyle(.white)

            if let myCode {
                Text(myCode)
                    .font(DotFont.mono(40, bold: true))
                    .tracking(8)
                    .foregroundStyle(Theme.lime)
                Text("Single-use · expires in 10 minutes")
                    .font(DotFont.mono(11)).foregroundStyle(.white.opacity(0.5))
            }

            Button {
                Task { await makeCode() }
            } label: {
                Text(generating ? "Generating…" : (myCode == nil ? "Get a one-time code" : "Get a new code"))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.08)))
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(generating)

            if let link = appModel.inviteLink() {
                ShareLink(item: link) {
                    HStack {
                        Image(systemName: "link")
                        Text("Share invite link")
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.08)))
                }
            }
        }
    }

    private func makeCode() async {
        generating = true
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
