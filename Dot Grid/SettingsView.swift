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

    @State private var myCode: String?
    @State private var generatingCode = false
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    @State private var showAddFriend = false
    @State private var showDeleteConfirm = false
    @State private var deleting = false

    private let symbols = ["★", "♥", "✦", "☺", "✿", "✚", "◆", "▲", "♪", "✺", "☀", "☆"]

    // ⬇️ PLACEHOLDERS — replace these with your real values.
    private let privacyPolicyURL = URL(string: "https://example.com/dotdot/privacy")!  // TODO: hosted privacy policy URL
    private let supportEmail = "support@example.com"                                   // TODO: your support email

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
    }

    // MARK: Profile

    private var profileCard: some View {
        card {
            HStack {
                Text("Profile").font(DotFont.heavy(15)).foregroundStyle(.white)
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
        }
    }

    private func saveProfile() async {
        saving = true
        try? await appModel.updateProfile(name: trimmedName, token: token)
        saving = false
    }

    // MARK: Your code

    private var codeCard: some View {
        card {
            Text("Your code").font(DotFont.heavy(15)).foregroundStyle(.white)
            Text("Generate a code and share it however you like. Single-use, expires in 10 minutes.")
                .font(DotFont.ui(13)).foregroundStyle(.white.opacity(0.5))

            if let myCode {
                HStack(spacing: 12) {
                    Text(myCode).font(DotFont.mono(36, bold: true)).tracking(6).foregroundStyle(Theme.lime)
                    Spacer()
                    Button { copy(myCode) } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc.fill")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.black.opacity(0.85))
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(.white))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(SquishyButtonStyle())
                }
            }

            Button { Task { await makeCode() } } label: {
                Text(generatingCode ? "generating…" : (myCode == nil ? "get a code" : "get a new code"))
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
            settingsRow("person.badge.plus", "Add a friend") { showAddFriend = true }
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
        myCode = try? await appModel.generateCode()
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

                // ⬇️ PLACEHOLDER policy text — replace with your real policy.
                Text("""
                [PLACEHOLDER — replace with your real privacy policy.]

                dotdot stores your name and identity token, the drawings and photos you send, and a per-device identifier, in order to deliver your messages to the friends you pair with. data syncs through Apple's CloudKit using your iCloud account. dotdot does not track you across apps and does not sell your data.

                you can delete your data anytime from settings → delete my data.
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
