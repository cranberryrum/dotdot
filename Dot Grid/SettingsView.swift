//
//  SettingsView.swift
//  Dot Grid
//
//  Opened by tapping the profile token. Edit profile, copy your code, add a friend,
//  read the privacy policy, contact support, and delete your data. On-brand per
//  DESIGN.md. Reuses existing profile-update and CloudKit logic — no new storage.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var symbol: String
    @State private var colorIndex: Int
    @State private var saving = false
    @State private var saveStatus: SaveStatus?
    @State private var saveStatusResetTask: Task<Void, Never>?

    @State private var generatingCode = false
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    @State private var showAddFriend = false
    @State private var showNotifPriming = false
    @State private var showDeleteConfirm = false
    @State private var deleting = false

    private let symbols = ["★", "♥", "✦", "☺", "✿", "✚", "◆", "▲", "♪", "✺", "☀", "☆"]

    private let privacyPolicyURL = URL(string: "https://github.com/cranberryrum/dotdot/blob/main/PRIVACY.md")!
    private let supportEmail = "adityakoltedes@gmail.com"

    init() {
        let p = AppModel.shared.profile
        _name = State(initialValue: p?.name ?? "")
        _symbol = State(initialValue: p?.token.symbol ?? "★")
        _colorIndex = State(initialValue: p?.token.colorIndex ?? 0)
    }

    private var token: IdentityToken { IdentityToken(symbol: symbol, colorIndex: colorIndex) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var profileChanged: Bool {
        guard let p = appModel.profile else { return true }
        return trimmedName != p.name || token != p.token
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    profileCard
                    codeCard
                    linksCard
                    deleteCard
                    versionFooter
                }
                .padding(20)
            }
            .background(Palette.screenBackground.ignoresSafeArea())
            .navigationTitle("settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("done") { dismiss() } }
            }
            .navigationDestination(isPresented: $showAddFriend) { AddFriendView() }
        }
        .font(DotFont.ui(17))
        .textCase(.lowercase)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showNotifPriming) { NotificationPrimingSheet() }
        .task { await appModel.loadOrMintCode() }
        .task { await appModel.notifications.refresh() }   // live status, read fresh
    }

    // MARK: Profile

    private var profileCard: some View {
        card {
            HStack {
                Text("profile").font(DotFont.heavy(15)).foregroundStyle(.white)
                Spacer()
                TokenBadge(token: token, size: 44)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: token)
            }

            TextField("", text: $name, prompt: Text("your name").foregroundStyle(.white.opacity(0.4)))
                .textInputAutocapitalization(.words)
                .font(DotFont.ui(18, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 12).padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(symbols, id: \.self) { option in
                        Button { symbol = option } label: {
                            Text(option)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.white.opacity(symbol == option ? 0.18 : 0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 10) {
                ForEach(Palette.entries.indices, id: \.self) { index in
                    Button { colorIndex = index } label: {
                        Circle()
                            .fill(Palette.color(at: index))
                            .frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(.white.opacity(colorIndex == index ? 0.95 : 0), lineWidth: 3).padding(2))
                            .scaleEffect(colorIndex == index ? 1 : 0.85)
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: colorIndex)
                    .accessibilityLabel(Palette.name(at: index))
                    .accessibilityAddTraits(colorIndex == index ? .isSelected : [])
                }
            }

            Button { Task { await saveProfile() } } label: {
                Text(saving ? "saving…" : "save profile")
                    .font(DotFont.ui(15, weight: .bold))
                    .foregroundStyle(token.prefersDarkText ? .black.opacity(0.85) : .white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(token.color))
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(trimmedName.isEmpty || !profileChanged || saving)
            .opacity(trimmedName.isEmpty || !profileChanged ? 0.5 : 1)

            // In-sheet feedback: toasts host behind sheets, so they'd be invisible here.
            if let saveStatus {
                Text(saveStatus.text)
                    .font(DotFont.ui(13, weight: .semibold))
                    .foregroundStyle(saveStatus.isError ? Theme.red : .white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
    }

    private struct SaveStatus { let text: String; let isError: Bool }

    private func saveProfile() async {
        saving = true
        withAnimation(Motion.surface) { saveStatus = nil }
        do {
            try await appModel.updateProfile(name: trimmedName, token: token)
            withAnimation(Motion.surface) { saveStatus = .init(text: "saved!", isError: false) }
            saveStatusResetTask?.cancel()
            saveStatusResetTask = Task {
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                withAnimation(Motion.surface) { saveStatus = nil }
            }
        } catch {
            withAnimation(Motion.surface) { saveStatus = .init(text: "couldn't save — try again", isError: true) }
        }
        saving = false
    }

    // MARK: Your code

    private var codeCard: some View {
        card {
            Text("your code").font(DotFont.heavy(15)).foregroundStyle(.white)
            Text("share this with friends so they can add you — it's good for 6 hours.")
                .font(DotFont.ui(13)).foregroundStyle(.white.opacity(0.5))

            if let code = appModel.inviteCode {
                HStack(spacing: 12) {
                    Text(code).font(DotFont.mono(36, bold: true)).tracking(6).foregroundStyle(Theme.lime)
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
            }

            Button { Task { await makeCode() } } label: {
                Text(generatingCode ? "generating…" : (appModel.inviteCode == nil ? "get a code" : "new code"))
                    .font(DotFont.ui(15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.08)))
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(generatingCode)
        }
    }

    // MARK: Links

    private var linksCard: some View {
        card {
            notificationsRow
            divider
            settingsRow("person.2.fill", "friends") { showAddFriend = true }
            divider
            NavigationLink { PrivacyPolicyView(url: privacyPolicyURL) } label: {
                rowLabel("hand.raised.fill", "Privacy policy")
            }
            .buttonStyle(.plain)
            divider
            settingsRow("envelope.fill", "Support") {
                if let url = URL(string: "mailto:\(supportEmail)") { UIApplication.shared.open(url) }
            }
        }
    }

    // MARK: Notifications (status indicator that routes — not a local toggle)

    private var notificationsRow: some View {
        Button { notificationsTapped() } label: {
            HStack(spacing: 12) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7)).frame(width: 24)
                Text("notifications").font(DotFont.ui(16, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                notificationsTrailing
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SquishyButtonStyle())
    }

    @ViewBuilder
    private var notificationsTrailing: some View {
        switch appModel.notifications.status {
        case .authorized, .provisional, .ephemeral:
            HStack(spacing: 6) {
                Circle().fill(Theme.mint).frame(width: 7, height: 7)
                Text("on").font(DotFont.mono(12, bold: true)).foregroundStyle(Theme.mint)
            }
        case .denied:
            HStack(spacing: 6) {
                Text("off").font(DotFont.mono(12, bold: true)).foregroundStyle(.white.opacity(0.4))
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.white.opacity(0.3))
            }
        default:   // notDetermined
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.white.opacity(0.3))
        }
    }

    private func notificationsTapped() {
        if appModel.notifications.canPrime {
            showNotifPriming = true               // notDetermined → our soft ask
        } else {
            appModel.notifications.openSystemSettings()   // denied (re-enable) or authorized (manage)
        }
    }

    // MARK: Delete

    private var deleteCard: some View {
        card {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "trash.fill")
                    Text(deleting ? "deleting…" : "delete my data")
                    Spacer()
                }
                .font(DotFont.ui(16, weight: .bold))
                .foregroundStyle(Theme.red)
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(deleting)
        }
        .alert("delete my data?", isPresented: $showDeleteConfirm) {
            Button("delete", role: .destructive) { Task { await runDelete() } }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("this removes your profile, friendships, and the drawings you've sent, then resets this app to a fresh start. drawings already delivered to a friend's device may still be on their device.")
        }
    }

    private func runDelete() async {
        deleting = true
        await appModel.deleteAllMyData()
        deleting = false
        dismiss()
    }

    // MARK: Version

    private var versionFooter: some View {
        Text(appVersion)
            .font(DotFont.mono(11))
            .foregroundStyle(.white.opacity(0.35))
            .padding(.top, 4)
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "dotdot v\(v) (\(b))"
    }

    // MARK: Helpers

    private func copy(_ code: String) {
        UIPasteboard.general.string = code
        withAnimation { copied = true }
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation { copied = false }
        }
    }

    private func makeCode() async {
        generatingCode = true
        copied = false
        await appModel.mintCode()
        generatingCode = false
    }

    private func settingsRow(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(icon, title) }
            .buttonStyle(SquishyButtonStyle())
    }

    private func rowLabel(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16, weight: .bold)).foregroundStyle(.white.opacity(0.7)).frame(width: 24)
            Text(title).font(DotFont.ui(16, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.white.opacity(0.3))
        }
        .contentShape(Rectangle())
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.boardBackground))
    }
}

// MARK: - Privacy policy

struct PrivacyPolicyView: View {
    let url: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("privacy policy")
                    .font(DotFont.heavy(22)).foregroundStyle(.white)

                Text("""
                no accounts, no logins. your identity is your iCloud account. dotdot does not track you, run ads, or sell your data.

                what's stored, in Apple's iCloud (CloudKit): your name and identity token, the drawings and photos you send, your friend connections, and an identifier used only to deliver messages to the right device. friends you pair with can see your name, token, and what you send them.

                you can delete your data anytime from settings → delete my data. note: a drawing already delivered to a friend's device may still exist on their device.

                questions: adityakoltedes@gmail.com
                """)
                .font(DotFont.ui(15))
                .foregroundStyle(.white.opacity(0.8))

                Link(destination: url) {
                    HStack(spacing: 8) {
                        Image(systemName: "safari.fill")
                        Text("view the full policy")
                    }
                    .font(DotFont.ui(15, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.cream))
                }
            }
            .padding(20)
        }
        .background(Palette.screenBackground.ignoresSafeArea())
        .navigationTitle("privacy")
        .navigationBarTitleDisplayMode(.inline)
        .textCase(.lowercase)
        .preferredColorScheme(.dark)
    }
}
