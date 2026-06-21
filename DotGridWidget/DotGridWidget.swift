//
//  DotGridWidget.swift
//  DotGridWidgetExtension
//
//  Display-only systemLarge widgets. They ONLY read the App Group via GridStore —
//  never the network. The app feeds them (local echo, or CloudKit pushes/fetches
//  writing received drawings) and calls reloadAllTimelines.
//

import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Entry

struct DotGridEntry: TimelineEntry {
    let date: Date
    let drawing: DisplayDrawing?
}

extension DisplayDrawing {
    static func placeholder(at date: Date) -> DisplayDrawing {
        .dots(.sample, senderID: "", senderName: "Friend", token: .placeholder, sentAt: date)
    }
}

// MARK: - Shared widget view (renders dots OR photo)

struct DotGridWidgetView: View {
    let drawing: DisplayDrawing?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            if let drawing, !drawing.senderID.isEmpty {
                TokenBadge(token: drawing.token, size: 30)
                    .padding(8)
            }
            if drawing == nil {
                Text("DOTS & PHOTOS FROM\nFRIENDS SHOW UP HERE")
                    .font(DotFont.mono(11, bold: true))
                    .tracking(1)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .containerBackground(for: .widget) { Theme.panel }
    }

    @ViewBuilder
    private var content: some View {
        if let drawing {
            switch drawing.kind {
            case .photo:
                if let data = drawing.imageData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    photoPlaceholder   // never blank or crash
                }
            case .dots:
                // Idle "throb" breath, which is widget-only.
                GridBoardView(grid: drawing.grid ?? .empty, spacing: 5)
                    .throb()
            }
        } else {
            GridBoardView(grid: .empty, spacing: 5)
        }
    }

    private var photoPlaceholder: some View {
        Image(systemName: "photo")
            .font(.system(size: 36, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Default widget: latest from any friend

struct LatestProvider: TimelineProvider {
    func placeholder(in context: Context) -> DotGridEntry {
        DotGridEntry(date: .now, drawing: .placeholder(at: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (DotGridEntry) -> Void) {
        let stored = GridStore.shared.latestDisplayDrawing()
        let drawing = (context.isPreview && stored == nil) ? DisplayDrawing.placeholder(at: .now) : stored
        completion(DotGridEntry(date: .now, drawing: drawing))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DotGridEntry>) -> Void) {
        let entry = DotGridEntry(date: .now, drawing: GridStore.shared.latestDisplayDrawing())
        // The app reloads timelines on send/receive; the widget never fetches.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct DotGridWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GridStore.widgetKind, provider: LatestProvider()) { entry in
            DotGridWidgetView(drawing: entry.drawing)
        }
        .configurationDisplayName("Dot Grid")
        .description("The latest drawing from a friend.")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Per-friend widget (pin one person)

struct FriendEntity: AppEntity {
    let id: String
    let name: String
    let tokenSymbol: String
    let tokenColor: Int

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Friend" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = FriendQuery()
}

struct FriendQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FriendEntity] {
        GridStore.shared.roster()
            .filter { identifiers.contains($0.id) }
            .map { FriendEntity(id: $0.id, name: $0.name, tokenSymbol: $0.token.symbol, tokenColor: $0.token.colorIndex) }
    }

    func suggestedEntities() async throws -> [FriendEntity] {
        GridStore.shared.roster()
            .map { FriendEntity(id: $0.id, name: $0.name, tokenSymbol: $0.token.symbol, tokenColor: $0.token.colorIndex) }
    }

    func defaultResult() async -> FriendEntity? {
        try? await suggestedEntities().first
    }
}

struct SelectFriendIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Pick a Friend" }
    static var description: IntentDescription { "Show one friend's latest drawing." }

    @Parameter(title: "Friend") var friend: FriendEntity?
}

struct FriendProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DotGridEntry {
        DotGridEntry(date: .now, drawing: .placeholder(at: .now))
    }

    func snapshot(for configuration: SelectFriendIntent, in context: Context) async -> DotGridEntry {
        DotGridEntry(date: .now, drawing: drawing(for: configuration) ?? .placeholder(at: .now))
    }

    func timeline(for configuration: SelectFriendIntent, in context: Context) async -> Timeline<DotGridEntry> {
        Timeline(entries: [DotGridEntry(date: .now, drawing: drawing(for: configuration))], policy: .never)
    }

    private func drawing(for configuration: SelectFriendIntent) -> DisplayDrawing? {
        guard let id = configuration.friend?.id else { return GridStore.shared.latestDisplayDrawing() }
        return GridStore.shared.displayDrawing(forFriend: id)
    }
}

struct DotGridFriendWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: GridStore.friendWidgetKind, intent: SelectFriendIntent.self, provider: FriendProvider()) { entry in
            DotGridWidgetView(drawing: entry.drawing)
        }
        .configurationDisplayName("Friend's Dot Grid")
        .description("Pin one friend's latest drawing.")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Bundle

@main
struct DotGridWidgetBundle: WidgetBundle {
    var body: some Widget {
        DotGridWidget()
        DotGridFriendWidget()
    }
}
