//
//  Caption.swift
//  Dot Grid
//
//  A free-dragged text caption baked into a photo or doodle before sending. Like the
//  photo stickers, the caption is composited INTO the sent JPEG (the widget stays
//  display-only), so what you place is exactly what your friend sees. Shared by both
//  the photo and doodle composers so the on-screen chip and the baked render are one
//  source of truth.
//

import SwiftUI

/// Caption type sizes, cycled by the editor's size button.
enum CaptionSize: CaseIterable {
    case small, medium, large
    var points: CGFloat {
        switch self {
        case .small: 15
        case .medium: 22
        case .large: 30
        }
    }
    /// The size the "Aa" indicator renders at in the editor's cycle button.
    var indicator: CGFloat {
        switch self {
        case .small: 12
        case .medium: 15
        case .large: 19
        }
    }
    var label: String {
        switch self {
        case .small: "small"
        case .medium: "medium"
        case .large: "large"
        }
    }
}

/// How wrapped caption lines align inside the text block (the block itself stays
/// anchored at `position` regardless).
enum CaptionAlignment: CaseIterable {
    case leading, center, trailing
    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
    var icon: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }
    var label: String {
        switch self {
        case .leading: "left"
        case .center: "center"
        case .trailing: "right"
        }
    }
}

/// One text caption. `position` is normalized (0...1) within the square canvas so it
/// scales cleanly from the on-screen chip to the high-res baked image.
struct CaptionOverlay {
    var text: String
    var position: CGPoint = CGPoint(x: 0.5, y: 0.5)   // born at the widget's center
    var colorIndex: Int
    var size: CaptionSize = .medium
    var alignment: CaptionAlignment = .center

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// One look for the caption everywhere: the editor field and the placed/baked chip use
/// the exact same type, so nothing jumps when typing ends.
enum CaptionStyle {
    static func font(_ size: CaptionSize) -> Font {
        .custom("HankenGrotesk-Regular", size: size.points).weight(.bold)
    }
}

/// The caption text as it appears — used BOTH on-screen and in the baked render.
/// Pure bare text: no container, no shadow. Legibility comes from picking a color
/// that works over the image.
struct CaptionChip: View {
    let caption: CaptionOverlay
    var maxWidth: CGFloat = 260

    var body: some View {
        Text(caption.text)
            .font(CaptionStyle.font(caption.size))
            .foregroundStyle(Palette.color(at: caption.colorIndex))
            .multilineTextAlignment(caption.alignment.text)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: maxWidth)
            .padding(10)                    // breathing room + a comfier drag target
            .contentShape(Rectangle())
    }
}

/// A focused typing moment presented full-screen over a frosted blur, so the whole
/// composer (tab toggle included) recedes behind it. The field floats centered; the
/// color / size / alignment panel hugs the keyboard (the cover's own keyboard
/// avoidance pins it just above). Tap the frost or "done" to commit; committing an
/// empty caption removes it. Present with `disablesAnimations` — the editor fades
/// itself in and out (the system slide would feel like a modal, and this isn't one).
struct CaptionEditor: View {
    @Binding var caption: CaptionOverlay
    var onDone: () -> Void
    var onRemove: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The frost only fades (scaling a full-bleed layer would reveal its edges), while
    // the controls scale in from 0.97 — nothing should appear from nothing.
    @State private var appeared = false

    var body: some View {
        ZStack {
            // Full-screen frost: blur + a light dim so what's behind stays readable as
            // context but clearly recedes — no more collisions with the chrome behind.
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.3))
                .ignoresSafeArea()
                .onTapGesture { fadeOutThen(onDone) }
                .opacity(appeared ? 1 : 0)

            VStack(spacing: 0) {
                HStack {
                    if !caption.isBlank {
                        Button { fadeOutThen(onRemove) } label: {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(SquishyButtonStyle())
                        .accessibilityLabel("remove caption")
                    }
                    Spacer()
                    Button { fadeOutThen(onDone) } label: {
                        Text("done")
                            .font(DotFont.ui(16, weight: .bold))
                            .foregroundStyle(.black.opacity(0.85))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Theme.cream))
                    }
                    .buttonStyle(SquishyButtonStyle())
                }
                .padding(.horizontal, 14)

                Spacer(minLength: 0)

                // The text floats in the middle of the space above the control panel.
                TextField("", text: $caption.text,
                          prompt: Text("say something").foregroundStyle(.white.opacity(0.35)),
                          axis: .vertical)
                    .focused($focused)
                    .font(CaptionStyle.font(caption.size))
                    .foregroundStyle(Palette.color(at: caption.colorIndex))
                    .tint(Palette.color(at: caption.colorIndex))
                    .multilineTextAlignment(caption.alignment.text)
                    .textInputAutocapitalization(.never)
                    .lineLimit(1...4)
                    .frame(maxWidth: 300)
                    .padding(.horizontal, 24)
                    .animation(.snappy(duration: 0.18), value: caption.size)

                Spacer(minLength: 0)

                // The edit panel hugs the keyboard — thumbs are already down there.
                VStack(spacing: 12) {
                    swatchRow
                    HStack(spacing: 10) {
                        sizeButton
                        alignmentButton
                    }
                }
                .padding(.bottom, 12)
            }
            .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
            .opacity(appeared ? 1 : 0)
        }
        .preferredColorScheme(.dark)   // the cover is its own environment — keep the frost dark
        .onAppear {
            focused = true
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.crisp(0.25)) { appeared = true }
        }
    }

    /// The editor owns its exit: fade the frost + controls, THEN dismiss (the cover
    /// itself is presented/dismissed with animations disabled).
    private func fadeOutThen(_ action: @escaping () -> Void) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : Motion.crisp(0.15)) { appeared = false }
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            action()
        }
    }

    private var swatchRow: some View {
        HStack(spacing: 0) {
            ForEach(Palette.entries.indices, id: \.self) { index in
                Button { caption.colorIndex = index } label: {
                    Circle()
                        .fill(Palette.color(at: index))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().strokeBorder(.white.opacity(caption.colorIndex == index ? 0.95 : 0), lineWidth: 2.5))
                        .scaleEffect(caption.colorIndex == index ? 1 : 0.84)
                        .frame(width: 44, height: 44)          // a full-size tap target per chip
                        .contentShape(Circle())
                }
                .buttonStyle(SquishyButtonStyle())
                .accessibilityLabel(Palette.name(at: index))
                .accessibilityAddTraits(caption.colorIndex == index ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.18), value: caption.colorIndex)
    }

    /// Cycles small → medium → large; the "Aa" grows with the chosen size.
    private var sizeButton: some View {
        Button {
            let all = CaptionSize.allCases
            let next = ((all.firstIndex(of: caption.size) ?? 0) + 1) % all.count
            caption.size = all[next]
        } label: {
            Text("Aa")
                .font(.custom("HankenGrotesk-Regular", size: caption.size.indicator).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 44)
                .background(Capsule().fill(.white.opacity(0.12)))
                .contentTransition(.interpolate)
        }
        .buttonStyle(SquishyButtonStyle())
        .animation(.snappy(duration: 0.18), value: caption.size)
        .accessibilityLabel("text size")
        .accessibilityValue(caption.size.label)
    }

    /// Cycles left → center → right; the icon reflects the current alignment.
    private var alignmentButton: some View {
        Button {
            let all = CaptionAlignment.allCases
            let next = ((all.firstIndex(of: caption.alignment) ?? 0) + 1) % all.count
            caption.alignment = all[next]
        } label: {
            Image(systemName: caption.alignment.icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 44)
                .background(Capsule().fill(.white.opacity(0.12)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("text alignment")
        .accessibilityValue(caption.alignment.label)
    }
}

/// A small floating "Aa" tool that opens the caption editor. Not baked — UI only.
struct CaptionToolButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "textformat")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.black.opacity(0.4)))
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("add caption")
    }
}
