//
//  RecipientPickerView.swift
//  Dot Grid
//
//  Pick who to send to. Pre-selects the last people you sent to.
//

import SwiftUI

struct RecipientPickerView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let onSend: ([String]) -> Void

    @State private var selected: Set<String> = []
    @State private var showAddFriend = false

    var body: some View {
        NavigationStack {
            Group {
                if appModel.friends.isEmpty {
                    emptyState
                } else {
                    friendList
                }
            }
            .background(Palette.screenBackground.ignoresSafeArea())
            .navigationTitle("Send to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddFriend = true } label: { Image(systemName: "person.badge.plus") }
                }
            }
            .safeAreaInset(edge: .bottom) { sendBar }
        }
        .font(DotFont.ui(17))
        .preferredColorScheme(.dark)
        .onAppear {
            let valid = Set(appModel.friends.map(\.id))
            selected = Set(appModel.lastRecipientIDs).intersection(valid)
        }
        .sheet(isPresented: $showAddFriend) { AddFriendView() }
    }

    private var friendList: some View {
        List {
            ForEach(appModel.friends) { friend in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if selected.contains(friend.id) { selected.remove(friend.id) }
                        else { selected.insert(friend.id) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        TokenBadge(token: friend.token, size: 36)
                        Text(friend.name).font(DotFont.ui(17, weight: .bold)).foregroundStyle(.white)
                        Spacer()
                        Image(systemName: selected.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(friend.id) ? friend.token.color : .white.opacity(0.3))
                            .font(.title3)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .listRowBackground(Palette.boardBackground)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 44)).foregroundStyle(.white.opacity(0.4))
            Text("No friends yet").font(DotFont.heavy(20)).foregroundStyle(.white)
            Text("Add a friend to start sending.")
                .font(DotFont.ui(15)).foregroundStyle(.white.opacity(0.5))
            Button("Add a friend") { showAddFriend = true }
                .font(DotFont.ui(16, weight: .bold))
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(Capsule().fill(.white))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sendBar: some View {
        Button {
            onSend(Array(selected))
            dismiss()
        } label: {
            Text(selected.isEmpty ? "PICK SOMEONE" : "SEND TO \(selected.count)")
                .font(DotFont.heavy(18))
                .contentTransition(.numericText())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 58)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Theme.blue)
                )
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(selected.isEmpty)
        .opacity(selected.isEmpty ? 0.5 : 1)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
