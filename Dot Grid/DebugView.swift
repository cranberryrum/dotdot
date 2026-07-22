//
//  DebugView.swift
//  Dot Grid
//
//  A peek at the live backend state — reached by long-pressing your token badge.
//  Handy while testing the CloudKit flows; safe to leave in (it's behind a hidden
//  gesture and shows no secrets).
//

import SwiftUI
import UIKit
import WidgetKit

/// Debug-only switches, readable from anywhere in the app target.
enum DebugFlags {
    static let replayFirstRunsKey = "debugReplayFirstRuns"
    /// While on, first-run one-shots (hints / nudges) play every time — the
    /// gates bypass their persisted budgets without consuming them.
    static var replayFirstRuns: Bool {
        UserDefaults.standard.bool(forKey: replayFirstRunsKey)
    }

    static let forceShimmerKey = "debugForceShimmer"
    /// While on, the wordmark shimmer (normally an unread-dotdots cue) plays on
    /// every app open and after closing any sheet — no unread required.
    static var forceShimmer: Bool {
        UserDefaults.standard.bool(forKey: forceShimmerKey)
    }

    // Widget-preview override controls (read only by DebugView; the override
    // itself lives in the App Group via GridStore so the widget can see it).
    static let widgetPreviewKey = "debugWidgetPreview"
    static let widgetPreviewFriendKey = "debugWidgetPreviewFriend"
    static let widgetPreviewReactionKey = "debugWidgetPreviewReaction"
}

/// What the widget-preview override shows. Raw values persist in defaults.
enum WidgetPreviewState: String, CaseIterable, Identifiable {
    case off, dots8, dots12, photo, doodle, empty

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "off (live data)"
        case .dots8: "dots 8×8"
        case .dots12: "dots 12×12"
        case .photo: "photo"
        case .doodle: "doodle"
        case .empty: "empty state"
        }
    }

    /// States that show artwork — the badge/reaction toggles only apply here.
    var hasArt: Bool { self != .off && self != .empty }
}

struct DebugView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @AppStorage(DebugFlags.replayFirstRunsKey) private var replayFirstRuns = false
    @AppStorage(DebugFlags.forceShimmerKey) private var forceShimmer = false
    @AppStorage(DebugFlags.widgetPreviewKey) private var widgetPreview = WidgetPreviewState.off
    @AppStorage(DebugFlags.widgetPreviewFriendKey) private var widgetPreviewFriend = true
    @AppStorage(DebugFlags.widgetPreviewReactionKey) private var widgetPreviewReaction = false

    var body: some View {
        NavigationStack {
            List {
                Section("iCloud") {
                    row("Status", appModel.accountDescription)
                    row("User ID", appModel.userID ?? "—")
                    row("Online", appModel.isOnline ? "Yes" : "No")
                }
                Section("Profile") {
                    if let p = appModel.profile {
                        row("Name", p.name)
                        row("Token", "\(p.token.symbol)  ·  color \(p.token.colorIndex)")
                    } else {
                        row("Profile", "none (not onboarded / signed out)")
                    }
                }
                Section("Onboarding") {
                    Button {
                        dismiss()
                        Task { @MainActor in
                            await Task.yield()
                            appModel.simulateOnboarding()
                        }
                    } label: {
                        Label("Simulate onboarding", systemImage: "rectangle.stack.badge.play")
                    }
                    Text("Runs the complete first-time flow without changing your profile or saved onboarding progress. Finishing returns you to the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Friends (\(appModel.friends.count))") {
                    if appModel.friends.isEmpty {
                        Text("No friends yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(appModel.friends) { f in
                            HStack {
                                TokenBadge(token: f.token, size: 24)
                                Text(f.name)
                                Spacer()
                                Text(f.id).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Section("Sending") {
                    row("Pending sends", "\(appModel.outbox.count)")
                    row("Last recipients", appModel.lastRecipientIDs.isEmpty ? "—" : "\(appModel.lastRecipientIDs.count)")
                    ForEach(appModel.outbox) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(item.kind.rawValue) → \(item.recipientIDs.count) recipient\(item.recipientIDs.count == 1 ? "" : "s")")
                                    .font(.callout)
                                Spacer()
                                Text("attempts \(item.attempts)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("queued \(item.createdAt.formatted(.relative(presentation: .named)))")
                                .font(.caption2).foregroundStyle(.secondary)
                            if let error = item.lastErrorDescription {
                                Text(error)
                                    .font(.caption2).foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if !appModel.outbox.isEmpty {
                        Button {
                            Task { working = true; await appModel.flushOutbox(); working = false }
                        } label: {
                            HStack {
                                Text("Flush now")
                                Spacer()
                                if working { ProgressView() }
                            }
                        }
                        .disabled(working)
                    }
                }
                Section("Widget preview") {
                    Picker("Show", selection: $widgetPreview) {
                        ForEach(WidgetPreviewState.allCases) { state in
                            Text(state.label).tag(state)
                        }
                    }
                    Toggle("Friend badge", isOn: $widgetPreviewFriend)
                        .disabled(!widgetPreview.hasArt)
                    Toggle("Reaction ❤️", isOn: $widgetPreviewReaction)
                        .disabled(!widgetPreview.hasArt)
                    Text("Overrides what the home-screen widgets show (small and large) with placeholder content, so every state can be eyeballed. Live data is untouched — pick \"off\" to restore the real widget. The doodle has a cream border at its edges: if the border is cut off anywhere, the widget is cropping.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("First-time hints") {
                    Toggle("Replay first-time hints", isOn: $replayFirstRuns)
                    Text("While on, one-shot hints play every time instead of just the first few — the pull-up chevron when a photo lands, and the inbox notifications nudge (if notifications are off). Budgets aren't consumed while replaying.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Shimmer") {
                    Toggle("Always play the inbox shimmer", isOn: $forceShimmer)
                    Text("While on, the wordmark sheen plays on every app open and after closing any sheet — no unread dotdot required. For eyeballing the shimmer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Last CloudKit error") {
                    Text(appModel.lastError ?? "none")
                        .font(.callout)
                        .foregroundStyle(appModel.lastError == nil ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
                Section {
                    Button {
                        Task { working = true; await appModel.debugRefresh(); working = false }
                    } label: {
                        HStack {
                            Text("Refresh (re-sync everything)")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working)
                }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onChange(of: widgetPreview) { applyWidgetPreview() }
            .onChange(of: widgetPreviewFriend) { applyWidgetPreview() }
            .onChange(of: widgetPreviewReaction) { applyWidgetPreview() }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    // MARK: - Widget preview override

    private func applyWidgetPreview() {
        let store = GridStore.shared
        switch widgetPreview {
        case .off:
            store.setWidgetDebugOverride(nil)
        case .empty:
            store.setWidgetDebugOverride(GridStore.WidgetDebugOverride(drawing: nil))
        case .dots8, .dots12, .photo, .doodle:
            store.setWidgetDebugOverride(GridStore.WidgetDebugOverride(drawing: previewDrawing()))
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func previewDrawing() -> DisplayDrawing? {
        // Borrow a real friend's identity when there is one, so the badge shows
        // an actual token from the roster instead of an invented one.
        let friend = appModel.friends.first
        let senderID = widgetPreviewFriend ? (friend?.id ?? "debug-friend") : ""
        let name = friend?.name ?? "maya"
        let token = friend?.token ?? IdentityToken(symbol: "🦊", colorIndex: 1)
        let reaction = widgetPreviewReaction ? "❤️" : nil

        switch widgetPreview {
        case .dots8:
            return DisplayDrawing(kind: .dots, grid: .sample, senderID: senderID,
                                  senderName: name, token: token, sentAt: .now,
                                  myReaction: reaction)
        case .dots12:
            return DisplayDrawing(kind: .dots, grid: Self.sample12, senderID: senderID,
                                  senderName: name, token: token, sentAt: .now,
                                  myReaction: reaction)
        case .photo:
            guard let data = Self.samplePhotoJPEG() else { return nil }
            return DisplayDrawing(kind: .photo, imageData: data, senderID: senderID,
                                  senderName: name, token: token, sentAt: .now,
                                  myReaction: reaction)
        case .doodle:
            guard let data = Self.sampleDoodleJPEG() else { return nil }
            return DisplayDrawing(kind: .doodle, imageData: data, senderID: senderID,
                                  senderName: name, token: token, sentAt: .now,
                                  myReaction: reaction)
        case .off, .empty:
            return nil
        }
    }

    /// A 12×12 checkerboard sweeping through the whole palette in size bands —
    /// exercises every color, all three chip sizes, and the tight small-widget gaps.
    private static let sample12: Grid = {
        var grid = Grid.empty(side: 12)
        let sizes: [ChipSize] = [.small, .medium, .large]
        for row in 0..<12 {
            for column in 0..<12 where (row + column).isMultiple(of: 2) {
                grid[row, column] = Cell(colorIndex: (row + column) % 8,
                                         size: sizes[(row / 4) % 3])
            }
        }
        return grid
    }()

    /// A photo-ish placeholder (gradient sky, sun, hill) so scaledToFill framing
    /// reads the way a real photo would.
    private static func samplePhotoJPEG() -> Data? {
        let size = CGSize(width: 800, height: 800)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(Theme.peri).cgColor, UIColor(Theme.pink).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor(Theme.yellow).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 500, y: 130, width: 190, height: 190))
            UIColor.black.withAlphaComponent(0.3).setFill()
            let hill = UIBezierPath()
            hill.move(to: CGPoint(x: 0, y: 620))
            hill.addQuadCurve(to: CGPoint(x: 800, y: 660), controlPoint: CGPoint(x: 400, y: 470))
            hill.addLine(to: CGPoint(x: 800, y: 800))
            hill.addLine(to: CGPoint(x: 0, y: 800))
            hill.close()
            hill.fill()
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    /// A doodle placeholder on the panel background (like real bakes), with a
    /// cream border hugging the edges — any cropping is instantly visible.
    private static func sampleDoodleJPEG() -> Data? {
        let size = CGSize(width: 800, height: 800)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(Theme.panel).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let border = UIBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 5))
            border.lineWidth = 10
            UIColor(Theme.cream).setStroke()
            border.stroke()

            let swoosh = UIBezierPath()
            swoosh.move(to: CGPoint(x: 120, y: 560))
            swoosh.addCurve(to: CGPoint(x: 680, y: 520),
                            controlPoint1: CGPoint(x: 240, y: 160),
                            controlPoint2: CGPoint(x: 560, y: 880))
            swoosh.lineWidth = 26
            swoosh.lineCapStyle = .round
            UIColor(Theme.lime).setStroke()
            swoosh.stroke()

            let arc = UIBezierPath()
            arc.move(to: CGPoint(x: 180, y: 280))
            arc.addQuadCurve(to: CGPoint(x: 640, y: 240), controlPoint: CGPoint(x: 420, y: 80))
            arc.lineWidth = 26
            arc.lineCapStyle = .round
            UIColor(Theme.pink).setStroke()
            arc.stroke()
        }
        return image.jpegData(compressionQuality: 0.8)
    }
}
