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

enum PairingOutcome: Equatable {
    case connected
    case solo
}

struct AddFriendView: View {
    @Environment(AppModel.self) private var appModel

    /// Present only during onboarding. The view still uses AppModel's real pairing
    /// methods; this closure reports which legitimate continuation the user chose.
    var onDone: ((PairingOutcome) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var didConnect = false

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
                if onDone != nil { onboardingHeader }
                if !appModel.isSignedIn { iCloudBanner }
                pairCard
                if onDone == nil || !appModel.friends.isEmpty { friendsCard }
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
            if !appModel.friends.isEmpty { didConnect = true }
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

    private var onboardingHeader: some View {
        OnboardingHeader(
            title: "who do you want on your home screen?",
            subtitle: "pair with a friend now, or make your first dotdot just for you."
        )
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: - iCloud notice (pairing needs an account; tap retries the check)

    private var iCloudBanner: some View {
        Button {
            Task { await appModel.onForeground() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "icloud.slash.fill")
                Text("sign into icloud to send & receive")
                    .font(DotFont.ui(14, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.boardBackground))
        }
        .buttonStyle(SquishyButtonStyle())
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
                    withAnimation(reduceMotion ? nil : Motion.settle) { tab = t }
                } label: {
                    Text(tabTitle(t))
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
                .frame(minHeight: 44)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
    }

    private func tabTitle(_ tab: PairTab) -> String {
        guard onDone != nil else { return tab.title }
        return tab == .add ? "enter their code" : "share my code"
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
                    .accessibilityLabel(copied ? "copied" : "copy code")
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
                        .frame(maxWidth: .infinity).frame(height: 44)
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
        Button {
            if let onDone {
                onDone(didConnect ? .connected : .solo)
            } else {
                dismiss()
            }
        } label: {
            Text(doneButtonTitle)
                .font(DotFont.ui(16, weight: .bold))
                .foregroundStyle(didConnect && onDone != nil ? Theme.ink : .white.opacity(0.72))
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(didConnect && onDone != nil ? Theme.cream : Palette.boardBackground)
                )
        }
        .buttonStyle(SquishyButtonStyle())
    }

    private var doneButtonTitle: String {
        guard onDone != nil else { return "done" }
        return didConnect ? "continue with a friend" : "try it with myself first"
    }

    // MARK: - Actions

    private func connect() async {
        connecting = true
        withAnimation(adaptiveSurfaceAnimation) { resultText = nil }
        do {
            try await appModel.addFriend(byCode: codeEntry)
            withAnimation(adaptiveSurfaceAnimation) {
                resultText = "connected. you’re ready to send."
                resultIsError = false
                didConnect = true
            }
            codeEntry = ""
        } catch {
            withAnimation(adaptiveSurfaceAnimation) {
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
            withAnimation(adaptiveSurfaceAnimation) { resultText = "couldn't make a code."; resultIsError = true }
        }
        refreshingCode = false
    }

    private func copy(_ code: String) {
        UIPasteboard.general.string = code
        withAnimation(reduceMotion ? Motion.reduced : Motion.settle) { copied = true }
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? Motion.reduced : Motion.settle) { copied = false }
        }
    }

    private func remove(_ friend: FriendInfo) async {
        removingID = friend.id
        await appModel.removeFriend(friend)
        removingID = nil
    }

    private var adaptiveSurfaceAnimation: Animation {
        reduceMotion ? Motion.reduced : Motion.surface
    }

    // MARK: - Card chrome

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.boardBackground))
    }
}
