//
//  AddFriendView.swift
//  Dot Grid
//
//  Friends screen: a compact pairing card (tab between "add a friend" and "your
//  code") and, below it, the list of your current friends with a remove option.
//  Pairing is code-only, instant, no approval.
//

import SwiftUI
import UIKit

struct AddFriendView: View {
    @Environment(AppModel.self) private var appModel

    /// Called when used inside onboarding ("continue"). Nil when shown as a sheet.
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    private enum PairTab: String, CaseIterable {
        case add, share
        var title: String { self == .add ? "add a friend" : "your code" }
    }
    @State private var tab: PairTab = .add
    @Namespace private var tabNS

    // Enter a code
    @State private var codeEntry = ""
    @State private var connecting = false
    @State private var resultText: String?
    @State private var resultIsError = false

    // Your code (the persistent code lives on AppModel)
    @State private var refreshingCode = false
    @State private var copied = false
    @State private var copiedResetTask: Task<Void, Never>?

    // Friends
    @State private var friendToRemove: FriendInfo?
    @State private var removingID: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                pairCard
                friendsCard
                doneButton
            }
            .padding(20)
        }
        .background(Palette.screenBackground.ignoresSafeArea())
        .font(DotFont.ui(17))
        .textCase(.lowercase)
        .preferredColorScheme(.dark)
        .task {
            await appModel.reloadFriends()
            await appModel.loadOrMintCode()
        }
        .alert(
            "remove friend?",
            isPresented: Binding(get: { friendToRemove != nil },
                                 set: { if !$0 { friendToRemove = nil } }),
            presenting: friendToRemove
        ) { friend in
            Button("remove", role: .destructive) { Task { await remove(friend) } }
            Button("cancel", role: .cancel) {}
        } message: { friend in
            Text("you'll stop sending to and receiving from \(friend.name). you can always pair again with a new code.")
        }
    }

    // MARK: - Pairing card (tabbed)

    private var pairCard: some View {
        card {
            tabToggle
            switch tab {
            case .add:   enterCodeContent
            case .share: shareContent
            }
            if let resultText {
                Text(resultText)
                    .font(DotFont.ui(13, weight: .bold))
                    .foregroundStyle(resultIsError ? Theme.red : Theme.mint)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
    }

    private var tabToggle: some View {
        HStack(spacing: 4) {
            ForEach(PairTab.allCases, id: \.self) { t in
                let selected = tab == t
                Button {
                    withAnimation(.snappy(duration: 0.22)) { tab = t }
                } label: {
                    Text(t.title)
                        .font(DotFont.ui(14, weight: .bold))
                        .foregroundStyle(selected ? Theme.ink : .white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Theme.cream)
                                    .matchedGeometryEffect(id: "pairPill", in: tabNS)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
    }

    private var enterCodeContent: some View {
        VStack(spacing: 12) {
            TextField("", text: $codeEntry, prompt: Text("6-digit code").foregroundStyle(.white.opacity(0.4)))
                .keyboardType(.numberPad)
                .font(DotFont.mono(26, bold: true))
                .tracking(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
                .onChange(of: codeEntry) { _, new in
                    codeEntry = String(new.filter(\.isNumber).prefix(6))
                }
            Button { Task { await connect() } } label: {
                Text(connecting ? "connecting…" : "connect")
                    .font(DotFont.ui(15, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(codeEntry.count != 6 || connecting)
            .opacity(codeEntry.count != 6 ? 0.5 : 1)
        }
    }

    private var shareContent: some View {
        VStack(spacing: 12) {
            if let code = appModel.inviteCode {
                HStack(spacing: 12) {
                    Text(code)
                        .font(DotFont.mono(34, bold: true))
                        .tracking(5)
                        .foregroundStyle(Theme.lime)
                    Spacer()
                    Button { copy(code) } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc.fill")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.black.opacity(0.85))
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(.white))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(SquishyButtonStyle())
                }
                if let exp = appModel.inviteCodeExpiresAt {
                    Text("expires \(exp, style: .relative) · reusable till then")
                        .font(DotFont.mono(11)).foregroundStyle(.white.opacity(0.5))
                }

                ShareLink(item: AppModel.inviteMessage(code: code)) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("share code")
                    }
                    .font(DotFont.ui(15, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(Capsule().fill(Theme.cream))
                }
                .buttonStyle(SquishyButtonStyle())

                Button { Task { await refreshCode() } } label: {
                    Text(refreshingCode ? "refreshing…" : "new code")
                        .font(DotFont.ui(14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
                }
                .buttonStyle(SquishyButtonStyle())
                .disabled(refreshingCode)
            } else {
                Text("make a code and share it with friends — it's good for 6 hours.")
                    .font(DotFont.ui(13)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button { Task { await refreshCode() } } label: {
                    Text(refreshingCode ? "generating…" : "get a code")
                        .font(DotFont.ui(15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.08)))
                }
                .buttonStyle(SquishyButtonStyle())
                .disabled(refreshingCode)
            }
        }
    }

    // MARK: - Friends list

    private var friendsCard: some View {
        card {
            HStack {
                Text("your friends").font(DotFont.heavy(15)).foregroundStyle(.white)
                Spacer()
                Text("\(appModel.friends.count)")
                    .font(DotFont.mono(13, bold: true)).foregroundStyle(.white.opacity(0.5))
            }

            if appModel.friends.isEmpty {
                emptyFriends
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(appModel.friends.enumerated()), id: \.element.id) { index, friend in
                        if index > 0 {
                            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                        }
                        friendRow(friend)
                    }
                }
            }
        }
    }

    private var emptyFriends: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white.opacity(0.25))
            Text("no friends yet")
                .font(DotFont.ui(15, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            Text("share your code, or enter a friend's.")
                .font(DotFont.ui(13)).foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func friendRow(_ friend: FriendInfo) -> some View {
        HStack(spacing: 12) {
            TokenBadge(token: friend.token, size: 40)
            Text(friend.name)
                .font(DotFont.ui(16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            if removingID == friend.id {
                ProgressView().tint(.white.opacity(0.5))
            } else {
                Button { friendToRemove = friend } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.28))
                }
                .buttonStyle(SquishyButtonStyle())
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Done

    private var doneButton: some View {
        Button { onDone?() ?? dismiss() } label: {
            Text(onDone == nil ? "done" : "continue to drawing")
                .font(DotFont.ui(16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.boardBackground))
        }
        .buttonStyle(SquishyButtonStyle())
    }

    // MARK: - Actions

    private func connect() async {
        connecting = true
        withAnimation(Motion.surface) { resultText = nil }
        do {
            try await appModel.addFriend(byCode: codeEntry)
            withAnimation(Motion.surface) { resultText = "connected! 🎉"; resultIsError = false }
            codeEntry = ""
        } catch {
            withAnimation(Motion.surface) {
                resultText = (error as? PairingError)?.errorDescription ?? "couldn't connect."
                resultIsError = true
            }
        }
        connecting = false
    }

    private func refreshCode() async {
        refreshingCode = true
        copied = false
        let ok = await appModel.mintCode()
        if !ok {
            withAnimation(Motion.surface) { resultText = "couldn't make a code."; resultIsError = true }
        }
        refreshingCode = false
    }

    private func copy(_ code: String) {
        UIPasteboard.general.string = code
        withAnimation(Motion.settle) { copied = true }
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.settle) { copied = false }
        }
    }

    private func remove(_ friend: FriendInfo) async {
        removingID = friend.id
        await appModel.removeFriend(friend)
        removingID = nil
    }

    // MARK: - Card chrome

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.boardBackground))
    }
}
