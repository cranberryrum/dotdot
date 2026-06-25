//
//  ToastView.swift
//  Dot Grid
//
//  One toast to rule them all. Every transient message in the app routes through
//  AppModel.showToast → this view, hosted once at the top of RootView. It enters
//  from the top and leaves the same way (spatial consistency, à la Sonner), is
//  swipe-up to dismiss with velocity, and owns its own enter/exit + auto-dismiss
//  so callers just set a string.
//

import SwiftUI

struct ToastView: View {
    let toast: AppModel.Toast
    /// Runs the toast's action (e.g. "undo"); does NOT dismiss — the view does that.
    var onAction: () -> Void
    /// Clears the toast from AppModel once it has animated off-screen.
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var offsetY: CGFloat = -240   // parked above the screen
    @State private var opacity: Double = 0
    @State private var dragY: CGFloat = 0
    @State private var dismissing = false

    private static let parked: CGFloat = -240

    var body: some View {
        card
            .offset(y: offsetY + dragY)
            .opacity(opacity)
            .gesture(swipe)
            .onAppear(perform: animateIn)
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(toast.duration))
                if !Task.isCancelled { animateOut() }
            }
    }

    // MARK: Card

    private var card: some View {
        HStack(spacing: 10) {
            if let icon = toast.icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Text(toast.message)
                .font(DotFont.ui(15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle = toast.actionTitle {
                Spacer(minLength: 6)
                Button {
                    onAction()      // run it now (instant feedback)…
                    animateOut()    // …and slide the toast away
                } label: {
                    Text(actionTitle)
                        .font(DotFont.ui(14, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule(style: .continuous).fill(Theme.cream))
                }
                .buttonStyle(SquishyButtonStyle())
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, toast.actionTitle == nil ? 16 : 7)
        .padding(.vertical, toast.actionTitle == nil ? 12 : 7)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(hex: 0x1C1C20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        )
        .frame(maxWidth: 460)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // MARK: Motion

    private func animateIn() {
        guard !reduceMotion else { offsetY = 0; opacity = 1; return }
        withAnimation(.spring(response: 0.46, dampingFraction: 0.82)) {
            offsetY = 0
            opacity = 1
        }
    }

    private func animateOut() {
        guard !dismissing else { return }
        dismissing = true
        guard !reduceMotion else { opacity = 0; onDismiss(); return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.92)) {
            offsetY = Self.parked
            opacity = 0
        } completion: {
            onDismiss()
        }
    }

    // MARK: Swipe-up to dismiss

    private var swipe: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !dismissing else { return }
                let t = value.translation.height
                // Up follows the finger 1:1; pulling down past rest rubber-bands.
                dragY = t < 0 ? t : t * 0.22
            }
            .onEnded { value in
                guard !dismissing else { return }
                let translation = value.translation.height
                let flick = value.predictedEndTranslation.height
                if translation < -34 || flick < -130 {   // dragged or flicked up
                    offsetY += dragY      // fold the drag into the base — no jump
                    dragY = 0
                    animateOut()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { dragY = 0 }
                }
            }
    }
}
