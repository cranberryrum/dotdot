//
//  SaveWatermark.swift
//  Dot Grid
//
//  The small "dotdot · sent date" mark baked onto every image saved to Photos —
//  so a dotdot that leaves the app still says where it's from and when it
//  happened. Sized for a 400pt reference canvas (the same one SaveToPhotos'
//  dots render uses); callers scale the whole composite up to the export's
//  actual pixel size, so this never needs to know its own final resolution.
//

import SwiftUI

struct SaveWatermark: View {
    let sentAt: Date

    var body: some View {
        HStack(spacing: 6) {
            (
                Text("dot").font(.custom("HankenGrotesk-MediumItalic", fixedSize: 12))
                + Text("dot").font(.custom("HankenGrotesk-ExtraLightItalic", fixedSize: 12))
            )
            .tracking(-0.9)
            Rectangle()
                .fill(.white.opacity(0.35))
                .frame(width: 1, height: 9)
            Text(Self.stamp(sentAt))
                .font(DotFont.mono(9, bold: true))
                .tracking(0.4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(.black.opacity(0.42))
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
        )
        // Solid fill + shadow (not a material) — the only combination that
        // survives ImageRenderer/UIGraphicsImageRenderer baking intact.
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        .fixedSize()
    }

    /// Absolute, not relative — this rides in a saved photo and may be read
    /// months later, long after "2h ago" would stop meaning anything.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM, h:mm a")
        return formatter.string(from: date).lowercased()
    }
}
