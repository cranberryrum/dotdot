//
//  TokenBadge.swift
//  Dot Grid
//
//  A person's identity token (emoji/initial on a palette color), or their
//  profile photo when they have one. Shared so the widget can show who a
//  drawing came from.
//

import SwiftUI
import UIKit

struct TokenBadge: View {
    let token: IdentityToken
    var avatarJPEG: Data? = nil
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let avatarJPEG, let ui = UIImage(data: avatarJPEG) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(token.symbol)
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(token.prefersDarkText ? Color.black.opacity(0.8) : .white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(token.color))
            }
        }
        .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }
}
