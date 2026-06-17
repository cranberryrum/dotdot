//
//  TokenBadge.swift
//  Dot Grid
//
//  A person's identity token (emoji/initial on a palette color). Shared so the
//  widget can show who a drawing came from.
//

import SwiftUI

struct TokenBadge: View {
    let token: IdentityToken
    var size: CGFloat = 28

    var body: some View {
        Text(token.symbol)
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(token.prefersDarkText ? Color.black.opacity(0.8) : .white)
            .frame(width: size, height: size)
            .background(Circle().fill(token.color))
            .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }
}
