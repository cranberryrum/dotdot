//
//  ComposerEmptyState.swift
//  Dot Grid
//
//  The empty-canvas hint shared by the photo and doodle composers. Same icon
//  treatment, text, spacing, and dim — so an empty photo board and an empty doodle
//  board read as the same kind of prompt when you switch tabs. Only the icon and
//  label differ (they name the action: choose a photo / draw something).
//

import SwiftUI

struct ComposerEmptyState: View {
    let systemImage: String
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .semibold))
            Text(title)
                .font(DotFont.ui(16, weight: .bold))
        }
        .foregroundStyle(.white.opacity(0.4))
    }
}
