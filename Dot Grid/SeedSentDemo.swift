//
//  SeedSentDemo.swift
//  Dot Grid
//
//  DEBUG-only fixture. Seeds the Sent tab with fixture sends (1/2/4 recipients)
//  so the recipient-display behavior can be checked or driven by a UI test
//  without a live iCloud account. Only activates behind the -SeedSentDemo
//  launch argument (see SentTabRecipientsUITests); never runs in Release.
//

#if DEBUG
import UIKit

enum SeedSentDemo {
    static func prepareIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-SeedSentDemo") else { return }

        func avatar(_ color: UIColor) -> Data {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
            let image = renderer.image { ctx in
                color.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            return image.jpegData(compressionQuality: 0.8) ?? Data()
        }

        let myAvatar = avatar(.systemRed)
        let now = Date()

        let alice = FriendInfo(id: "f-alice", name: "alice", token: IdentityToken(symbol: "A", colorIndex: 1))
        let ben = FriendInfo(id: "f-ben", name: "ben", token: IdentityToken(symbol: "B", colorIndex: 2),
                             avatarJPEG: avatar(.systemBlue))
        let cara = FriendInfo(id: "f-cara", name: "cara", token: IdentityToken(symbol: "C", colorIndex: 3))
        let dev = FriendInfo(id: "f-dev", name: "dev", token: IdentityToken(symbol: "D", colorIndex: 4),
                            avatarJPEG: avatar(.systemGreen))

        func echo(id: String) -> DisplayDrawing {
            .dots(.sample, senderID: "", senderName: "you", token: IdentityToken(symbol: "Y", colorIndex: 0),
                  sentAt: now, messageID: id, avatarJPEG: myAvatar)
        }

        let messages = [
            SentMessage(id: "seed-1", drawing: echo(id: "seed-1"), recipients: [alice], status: .sent),
            SentMessage(id: "seed-2", drawing: echo(id: "seed-2"), recipients: [alice, ben], status: .sent),
            SentMessage(id: "seed-3", drawing: echo(id: "seed-3"), recipients: [alice, ben, cara, dev], status: .sent),
        ]
        for m in messages { GridStore.shared.appendSent(m) }
    }
}
#endif
