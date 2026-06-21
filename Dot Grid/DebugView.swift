//
//  DebugView.swift
//  Dot Grid
//
//  A peek at the live backend state — reached by long-pressing your token badge.
//  Handy while testing the CloudKit flows; safe to leave in (it's behind a hidden
//  gesture and shows no secrets).
//

import SwiftUI

struct DebugView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

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
