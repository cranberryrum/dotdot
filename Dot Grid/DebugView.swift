//
//  DebugView.swift
//  Dot Grid
//
//  A peek at the live backend state — reached by long-pressing your token badge.
//  Handy while testing the CloudKit flows; safe to leave in (it's behind a hidden
//  gesture and shows no secrets).
//

import SwiftUI

/// Debug-only switches, readable from anywhere in the app target.
enum DebugFlags {
    static let replayFirstRunsKey = "debugReplayFirstRuns"
    /// While on, first-run one-shots (hints / nudges) play every time — the
    /// gates bypass their persisted budgets without consuming them.
    static var replayFirstRuns: Bool {
        UserDefaults.standard.bool(forKey: replayFirstRunsKey)
    }

    static let forceShimmerKey = "debugForceShimmer"
    /// While on, the wordmark shimmer (normally an unread-dotdots cue) plays on
    /// every app open and after closing any sheet — no unread required.
    static var forceShimmer: Bool {
        UserDefaults.standard.bool(forKey: forceShimmerKey)
    }
}

struct DebugView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @AppStorage(DebugFlags.replayFirstRunsKey) private var replayFirstRuns = false
    @AppStorage(DebugFlags.forceShimmerKey) private var forceShimmer = false

    var body: some View {
        NavigationStack {
            List {
                Section("iCloud") {
                    row("Status", appModel.accountDescription)
                    row("User ID", appModel.userID ?? "—")
                    row("Online", appModel.isOnline ? "Yes" : "No")
                }
                Section("Profile") {
                    if let p = appModel.profile {
                        row("Name", p.name)
                        row("Token", "\(p.token.symbol)  ·  color \(p.token.colorIndex)")
                    } else {
                        row("Profile", "none (not onboarded / signed out)")
                    }
                }
                Section("Friends (\(appModel.friends.count))") {
                    if appModel.friends.isEmpty {
                        Text("No friends yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(appModel.friends) { f in
                            HStack {
                                TokenBadge(token: f.token, size: 24)
                                Text(f.name)
                                Spacer()
                                Text(f.id).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Section("Sending") {
                    row("Pending sends", "\(appModel.outbox.count)")
                    row("Last recipients", appModel.lastRecipientIDs.isEmpty ? "—" : "\(appModel.lastRecipientIDs.count)")
                    ForEach(appModel.outbox) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(item.kind.rawValue) → \(item.recipientIDs.count) recipient\(item.recipientIDs.count == 1 ? "" : "s")")
                                    .font(.callout)
                                Spacer()
                                Text("attempts \(item.attempts)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("queued \(item.createdAt.formatted(.relative(presentation: .named)))")
                                .font(.caption2).foregroundStyle(.secondary)
                            if let error = item.lastErrorDescription {
                                Text(error)
                                    .font(.caption2).foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if !appModel.outbox.isEmpty {
                        Button {
                            Task { working = true; await appModel.flushOutbox(); working = false }
                        } label: {
                            HStack {
                                Text("Flush now")
                                Spacer()
                                if working { ProgressView() }
                            }
                        }
                        .disabled(working)
                    }
                }
                Section("First-time hints") {
                    Toggle("Replay first-time hints", isOn: $replayFirstRuns)
                    Text("While on, one-shot hints play every time instead of just the first few — the pull-up chevron when a photo lands, and the inbox notifications nudge (if notifications are off). Budgets aren't consumed while replaying.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Shimmer") {
                    Toggle("Always play the inbox shimmer", isOn: $forceShimmer)
                    Text("While on, the wordmark sheen plays on every app open and after closing any sheet — no unread dotdot required. For eyeballing the shimmer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Last CloudKit error") {
                    Text(appModel.lastError ?? "none")
                        .font(.callout)
                        .foregroundStyle(appModel.lastError == nil ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
                Section {
                    Button {
                        Task { working = true; await appModel.debugRefresh(); working = false }
                    } label: {
                        HStack {
                            Text("Refresh (re-sync everything)")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working)
                }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
