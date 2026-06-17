//
//  GridStore.swift
//  Dot Grid
//
//  The single seam between everything and the App Group container. The composer
//  saves its canvas here, CloudKit writes received drawings here, and the widget
//  reads here. The widget NEVER touches the network — it only reads this store.
//

import Foundation

struct GridStore {
    static let appGroupID = "group.Kolte.Dot-Grid"
    static let widgetKind = "DotGridWidget"
    static let friendWidgetKind = "DotGridFriendWidget"

    static let shared = GridStore()

    private var defaults: UserDefaults? { UserDefaults(suiteName: Self.appGroupID) }

    // MARK: - Keys

    private static let canvasKey = "currentGrid"        // composer's last canvas
    private static let localEchoKey = "localEcho"       // your own last send (fallback display)
    private static let latestReceivedKey = "latestReceived"
    private static let rosterKey = "friendRoster"
    private static let profileKey = "myProfile"
    private static let outboxKey = "outbox"
    private static func friendDisplayKey(_ id: String) -> String { "display.\(id)" }

    // MARK: - Composer canvas (last in-editor drawing)

    /// Persist the in-progress canvas so reopening the app restores it.
    func save(_ grid: Grid) { encode(grid, forKey: Self.canvasKey) }

    /// The composer's starting canvas.
    func load() -> Grid { decode(Grid.self, forKey: Self.canvasKey) ?? .empty }

    // MARK: - Widget display

    /// Your own outgoing drawing, shown on your widget until a friend sends one.
    /// `senderID` is empty so the widget shows no "from" badge on your own work.
    /// Works without a profile, so the local loop is solid even before iCloud.
    func saveLocalEcho(grid: Grid, token: IdentityToken) {
        let drawing = DisplayDrawing(
            grid: grid, senderID: "", senderName: "You", token: token, sentAt: Date()
        )
        encode(drawing, forKey: Self.localEchoKey)
    }

    /// A drawing received from a friend. Updates that friend's slot and, if it's
    /// the newest, the "latest from anyone" slot the default widget shows.
    func saveReceived(_ drawing: DisplayDrawing) {
        encode(drawing, forKey: Self.friendDisplayKey(drawing.senderID))
        if let current = decode(DisplayDrawing.self, forKey: Self.latestReceivedKey),
           current.sentAt >= drawing.sentAt {
            return
        }
        encode(drawing, forKey: Self.latestReceivedKey)
    }

    /// What the default widget shows: latest from any friend, else your own echo.
    func latestDisplayDrawing() -> DisplayDrawing? {
        decode(DisplayDrawing.self, forKey: Self.latestReceivedKey)
            ?? decode(DisplayDrawing.self, forKey: Self.localEchoKey)
    }

    /// What a pinned per-friend widget shows.
    func displayDrawing(forFriend id: String) -> DisplayDrawing? {
        decode(DisplayDrawing.self, forKey: Self.friendDisplayKey(id))
    }

    // MARK: - Friend roster (drives the configurable widget's picker)

    func saveRoster(_ friends: [FriendInfo]) { encode(friends, forKey: Self.rosterKey) }
    func roster() -> [FriendInfo] { decode([FriendInfo].self, forKey: Self.rosterKey) ?? [] }

    // MARK: - Profile cache

    func saveProfile(_ profile: Profile?) {
        guard let profile else { defaults?.removeObject(forKey: Self.profileKey); return }
        encode(profile, forKey: Self.profileKey)
    }
    func loadProfile() -> Profile? { decode(Profile.self, forKey: Self.profileKey) }

    // MARK: - Outbox (offline send queue)

    func loadOutbox() -> [QueuedSend] { decode([QueuedSend].self, forKey: Self.outboxKey) ?? [] }
    func saveOutbox(_ items: [QueuedSend]) { encode(items, forKey: Self.outboxKey) }

    // MARK: - Reset (iCloud account switch starts fresh)

    func clearSharedState() {
        guard let defaults else { return }
        for key in [Self.localEchoKey, Self.latestReceivedKey, Self.rosterKey, Self.profileKey, Self.outboxKey] {
            defaults.removeObject(forKey: key)
        }
        for friend in roster() {
            defaults.removeObject(forKey: Self.friendDisplayKey(friend.id))
        }
    }

    // MARK: - Codable helpers

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let defaults, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
