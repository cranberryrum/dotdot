//
//  AppStoreCapture.swift
//  Dot Grid
//
//  Deterministic, DEBUG-only launch states for marketing captures. These presets
//  are never compiled into release builds and only run when an explicit simulator
//  launch argument or environment variable is present.
//

#if DEBUG
import Foundation
import PencilKit
import SwiftUI
import UIKit
import WidgetKit

enum AppStoreCapture {
    enum Scene: String {
        case widget
        case dots
        case photo
        case doodle
        case reactions
    }

    private static let argumentPrefix = "--dotdot-capture="

    static var scene: Scene? {
        if let raw = ProcessInfo.processInfo.environment["DOTDOT_CAPTURE_SCENE"] {
            return Scene(rawValue: raw)
        }
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix(argumentPrefix)
        }) else { return nil }
        return Scene(rawValue: String(argument.dropFirst(argumentPrefix.count)))
    }

    static var isActive: Bool { scene != nil }

    static let me = Profile(
        id: "app-store-me",
        name: "adi",
        token: IdentityToken(symbol: "a", colorIndex: 0)
    )
    static let maya = FriendInfo(
        id: "app-store-maya",
        name: "maya",
        token: IdentityToken(symbol: "m", colorIndex: 1)
    )
    static let rio = FriendInfo(
        id: "app-store-rio",
        name: "rio",
        token: IdentityToken(symbol: "r", colorIndex: 2)
    )

    /// Seed before AppModel.shared is first created so its local-first cache hydrates
    /// with the same profile, friends, and composer state on every capture launch.
    static func prepareIfNeeded() {
        guard let scene else { return }

        let defaults = UserDefaults.standard
        defaults.set(false, forKey: DebugFlags.replayFirstRunsKey)
        defaults.set(false, forKey: DebugFlags.forceShimmerKey)
        defaults.set(true, forKey: "notif.feedNudgeDismissed")
        defaults.set(99, forKey: "photoDoodleHintCount")
        defaults.set([maya.id, rio.id], forKey: "lastRecipients")
        OnboardingStore().save(.existingUser)
        ComposerCoachStore().save(.disabled)

        switch scene {
        case .widget:
            defaults.set(ComposeMode.dots.rawValue, forKey: "composeMode")
            defaults.set(0, forKey: "accentColorIndex")
        case .dots:
            defaults.set(ComposeMode.dots.rawValue, forKey: "composeMode")
            defaults.set(1, forKey: "accentColorIndex")
        case .photo:
            defaults.set(ComposeMode.photo.rawValue, forKey: "composeMode")
            defaults.set(4, forKey: "accentColorIndex")
        case .doodle:
            defaults.set(ComposeMode.doodle.rawValue, forKey: "composeMode")
            defaults.set(2, forKey: "accentColorIndex")
        case .reactions:
            defaults.set(ComposeMode.dots.rawValue, forKey: "composeMode")
            defaults.set(6, forKey: "accentColorIndex")
        }

        let store = GridStore.shared
        store.saveProfile(me)
        store.saveRoster([maya, rio])
        store.save(helloGrid)
        store.saveOutbox([])

        let now = Date()
        let received = DisplayDrawing.dots(
            heartGrid,
            senderID: maya.id,
            senderName: maya.name,
            token: maya.token,
            sentAt: now.addingTimeInterval(-75),
            messageID: "app-store-received"
        )
        let sentDrawing = DisplayDrawing.dots(
            helloGrid,
            senderID: me.id,
            senderName: me.name,
            token: me.token,
            sentAt: now.addingTimeInterval(-210),
            messageID: "app-store-sent"
        )
        let sent = SentMessage(
            id: "app-store-sent",
            drawing: sentDrawing,
            recipients: [maya, rio],
            reactions: [
                ReactionInfo(emoji: "❤️", reactorID: maya.id, reactorName: maya.name,
                             at: now.addingTimeInterval(-45)),
                ReactionInfo(emoji: "🔥", reactorID: rio.id, reactorName: rio.name,
                             at: now.addingTimeInterval(-30)),
            ],
            status: .sent
        )
        store.setCaptureHistories(received: [received], sent: [sent])

        let widgetDrawing = DisplayDrawing(
            kind: .dots,
            grid: heartGrid,
            senderID: maya.id,
            senderName: maya.name,
            token: maya.token,
            sentAt: now,
            messageID: "app-store-widget",
            myReaction: scene == .reactions ? "❤️" : nil
        )
        store.setWidgetDebugOverride(.init(drawing: widgetDrawing))
        WidgetCenter.shared.reloadAllTimelines()
    }

    static var mainPhoto: UIImage? { captureImage(named: "friends-main.png") }
    static var selfiePhoto: UIImage? { captureImage(named: "friends-selfie.png") }

    /// Marketing photos are copied into the simulator's Documents directory by the
    /// capture workflow. They never enter the app bundle or the Release asset catalog.
    private static func captureImage(named name: String) -> UIImage? {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else { return nil }
        return UIImage(contentsOfFile: documents
            .appendingPathComponent("AppStoreCapture", isDirectory: true)
            .appendingPathComponent(name)
            .path)
    }

    static let helloGrid: Grid = grid(from: [
        "........",
        ".B.B.P.Y",
        ".B.B.P.Y",
        ".BBB.P.Y",
        ".B.B.P..",
        ".B.B.P.Y",
        "........",
        "........",
    ], colors: ["B": 0, "P": 1, "Y": 4])

    static let heartGrid: Grid = grid(from: [
        "........",
        ".PP..YY.",
        "PPPPYYYY",
        "PPPPYYYY",
        ".PPYYMM.",
        "..YYMM..",
        "...MM...",
        "........",
    ], colors: ["P": 1, "Y": 4, "M": 5])

    private static func grid(from art: [String], colors: [Character: Int]) -> Grid {
        var grid = Grid.empty(side: art.count)
        for (row, line) in art.enumerated() {
            for (column, character) in line.enumerated() {
                guard let colorIndex = colors[character] else { continue }
                let size: ChipSize = (row + column).isMultiple(of: 4) ? .large : .medium
                grid[row, column] = Cell(colorIndex: colorIndex, size: size)
            }
        }
        return grid
    }

    /// A real PencilKit drawing for the doodle capture: the preset installs native
    /// strokes into the same canvas users draw on, so the capture stays WYSIWYG.
    static func doodleDrawing(side: CGFloat) -> PKDrawing {
        let paths: [([CGPoint], Int, CGFloat)] = [
            // m
            ([.init(x: 0.07, y: 0.63), .init(x: 0.07, y: 0.34),
              .init(x: 0.14, y: 0.52), .init(x: 0.21, y: 0.34),
              .init(x: 0.21, y: 0.63)], 1, 12),
            // i + dot
            ([.init(x: 0.27, y: 0.45), .init(x: 0.27, y: 0.63)], 4, 11),
            ([.init(x: 0.27, y: 0.36), .init(x: 0.275, y: 0.365)], 4, 15),
            // s s
            ([.init(x: 0.40, y: 0.43), .init(x: 0.35, y: 0.40),
              .init(x: 0.31, y: 0.44), .init(x: 0.32, y: 0.50),
              .init(x: 0.40, y: 0.54), .init(x: 0.40, y: 0.60),
              .init(x: 0.35, y: 0.64), .init(x: 0.31, y: 0.61)], 0, 11),
            ([.init(x: 0.54, y: 0.43), .init(x: 0.49, y: 0.40),
              .init(x: 0.45, y: 0.44), .init(x: 0.46, y: 0.50),
              .init(x: 0.54, y: 0.54), .init(x: 0.54, y: 0.60),
              .init(x: 0.49, y: 0.64), .init(x: 0.45, y: 0.61)], 6, 11),
            // u
            ([.init(x: 0.62, y: 0.43), .init(x: 0.62, y: 0.59),
              .init(x: 0.66, y: 0.64), .init(x: 0.71, y: 0.59),
              .init(x: 0.71, y: 0.43), .init(x: 0.71, y: 0.63)], 2, 12),
            // !
            ([.init(x: 0.79, y: 0.35), .init(x: 0.79, y: 0.56)], 3, 11),
            ([.init(x: 0.79, y: 0.64), .init(x: 0.795, y: 0.645)], 3, 15),
            // underline swoop
            ([.init(x: 0.13, y: 0.73), .init(x: 0.29, y: 0.76),
              .init(x: 0.47, y: 0.75), .init(x: 0.65, y: 0.72),
              .init(x: 0.82, y: 0.75)], 5, 7),
        ]

        let strokes = paths.map { points, colorIndex, width in
            captureStroke(points: points.map { CGPoint(x: $0.x * side, y: $0.y * side) },
                          color: UIColor(Palette.color(at: colorIndex)), width: width)
        }
        return PKDrawing(strokes: strokes)
    }

    private static func captureStroke(points: [CGPoint], color: UIColor, width: CGFloat) -> PKStroke {
        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: TimeInterval(index) * 0.035,
                size: CGSize(width: width, height: width),
                opacity: 0.96,
                force: 0.7,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(.crayon, color: color),
            path: PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        )
    }
}
#endif
