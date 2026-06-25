//
//  NotificationPrimingSheet.swift
//  Dot Grid
//
//  The soft ask — a warm bottom sheet that explains why we'd like to notify, with a
//  clear "turn on" (the ONLY place that triggers the real OS prompt) and a no-penalty
//  "not now". Shown at most once automatically; declining costs nothing, so the OS
//  prompt stays available for later.
//

import SwiftUI

struct NotificationPrimingSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var requesting = false

    private var gate: NotificationGate { appModel.notifications }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Theme.blue.opacity(0.18)).frame(width: 84, height: 84)
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.blue)
                    .symbolRenderingMode(.hierarchical)
            }
            .padding(.top, 38)

            Text("get a little ping")
                .font(DotFont.heavy(24))
                .foregroundStyle(.white)
                .padding(.top, 20)

            Text("we'll let you know when a friend draws you something or connects with you. that's it — no spam, ever.")
                .font(DotFont.ui(16))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 10)
                .padding(.horizontal, 26)

            Spacer(minLength: 26)

            VStack(spacing: 8) {
                Button { Task { await turnOn() } } label: {
                    Text(requesting ? "…" : "turn on")
                        .font(DotFont.heavy(18))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.cream))
                }
                .buttonStyle(SquishyButtonStyle())
                .disabled(requesting)

                Button { notNow() } label: {
                    Text("not now")
                        .font(DotFont.ui(16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity).frame(height: 44)
                }
                .buttonStyle(SquishyButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.screenBackground.ignoresSafeArea())
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.screenBackground)
        .font(DotFont.ui(17))
        .textCase(.lowercase)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(requesting)
        .onAppear { gate.notePrimingShown() }   // counts as shown however it's closed
    }

    private func turnOn() async {
        requesting = true
        await gate.requestAuthorization()   // the one real OS prompt
        requesting = false
        dismiss()
    }

    private func notNow() {
        gate.declinePriming()   // soft — no penalty, OS prompt stays available
        dismiss()
    }
}
