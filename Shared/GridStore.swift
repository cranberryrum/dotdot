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
    static let appGroupID = "group.com.kolteaditya.dotgrid"
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
    private static let receivedHistoryKey = "receivedHistory"   // inbox: dotdots from others
    private static let sentHistoryKey = "sentHistory"           // inbox: dotdots you sent
    private static let latestReceivedAtKey = "latestReceivedAt" // unread check (a Date, no blob)
    private static func friendDisplayKey(_ id: String) -> String { "display.\(id)" }

    /// How many messages each inbox feed keeps. Bounds the App Group footprint —
    /// these arrays hold image JPEGs for photo/doodle sends.
    static let historyLimit = 60

    // MARK: - Composer canvas (last in-editor drawing)

    /// Persist the in-progress canvas so reopening the app restores it.
    func save(_ grid: Grid) { encode(grid, forKey: Self.canvasKey) }

    /// The composer's starting canvas.
    func load() -> Grid { decode(Grid.self, forKey: Self.canvasKey) ?? .empty }

    // MARK: - Widget display

    /// Your own outgoing message, shown on your widget until a friend sends one.
    /// `senderID` is empty so the widget shows no "from" badge on your own work.
    /// Works without a profile, so the local loop is solid even before iCloud.
    func saveLocalEcho(_ drawing: DisplayDrawing) {
        encode(drawing, forKey: Self.localEchoKey)
    }

    /// A drawing received from a friend. Updates that friend's slot, appends to the
    /// inbox's "received" feed, and, if it's the newest, the "latest from anyone"
    /// slot the default widget shows. The single choke point for incoming drawings.
    func saveReceived(_ drawing: DisplayDrawing) {
        encode(drawing, forKey: Self.friendDisplayKey(drawing.senderID))
        prependReceivedHistory(drawing)
        // A lightweight high-water timestamp so the inbox can check for unread
        // dotdots without decoding the stored image blobs.
        let prevNewest = (defaults?.object(forKey: Self.latestReceivedAtKey) as? Date) ?? .distantPast
        if drawing.sentAt > prevNewest {
            defaults?.set(drawing.sentAt, forKey: Self.latestReceivedAtKey)
        }
        if let current = decode(DisplayDrawing.self, forKey: Self.latestReceivedKey),
           current.sentAt >= drawing.sentAt {
            return
        }
        encode(drawing, forKey: Self.latestReceivedKey)
    }

    /// When the newest received dotdot arrived, or nil if none. A plain Date, so the
    /// unread check stays cheap (no image decode). Forward-only: dotdots received
    /// before this shipped don't count.
    func latestReceivedAt() -> Date? {
        defaults?.object(forKey: Self.latestReceivedAtKey) as? Date
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

    // MARK: - Inbox history (received + sent feeds)

    /// Newest-first list of dotdots received from friends. Twins are healed on
    /// read: the app's fetch and the notification service extension are two
    /// PROCESSES racing read-modify-write on this array, so the prepend-time
    /// check can miss a copy the other process hadn't flushed yet. Duplicate
    /// rows also collide in the inbox feed's ForEach identity, which makes
    /// LazyVStack render ghost copies and blank-until-scrolled cards.
    func receivedHistory() -> [DisplayDrawing] {
        let stored = decode([DisplayDrawing].self, forKey: Self.receivedHistoryKey) ?? []
        let cleaned = Self.dedupingReceived(stored)
        if cleaned.count != stored.count {
            encode(cleaned, forKey: Self.receivedHistoryKey)   // heal once, stay clean
        }
        return cleaned
    }

    /// Collapse twins — same messageID, or same sender + exact sentAt (the
    /// pre-messageID identity, which also catches a refetched old drawing whose
    /// stored copy predates messageID). Keeps the first (newest) copy, but never
    /// loses a reaction stamped on a later twin.
    nonisolated static func dedupingReceived(_ items: [DisplayDrawing]) -> [DisplayDrawing] {
        var kept: [DisplayDrawing] = []
        var indexByMessageID: [String: Int] = [:]
        var indexBySenderTime: [String: Int] = [:]
        for item in items {
            let timeKey = "\(item.senderID)|\(item.sentAt.timeIntervalSinceReferenceDate)"
            let twin = item.messageID.flatMap { indexByMessageID[$0] } ?? indexBySenderTime[timeKey]
            if let twin {
                if kept[twin].myReaction == nil { kept[twin].myReaction = item.myReaction }
                continue
            }
            if let messageID = item.messageID { indexByMessageID[messageID] = kept.count }
            indexBySenderTime[timeKey] = kept.count
            kept.append(item)
        }
        return kept
    }

    private func prependReceivedHistory(_ drawing: DisplayDrawing) {
        var items = receivedHistory()
        // Idempotent: the notification service extension AND the app's fetch paths
        // can both deliver the same record — the second arrival is a no-op (which
        // also preserves any reaction already attached locally). Matched by
        // messageID OR sender+time, so a stored copy that predates messageID
        // still counts as the same drawing.
        let duplicate = items.contains { existing in
            if let messageID = drawing.messageID, existing.messageID == messageID { return true }
            return existing.senderID == drawing.senderID && existing.sentAt == drawing.sentAt
        }
        guard !duplicate else { return }
        items.insert(drawing, at: 0)
        if items.count > Self.historyLimit { items = Array(items.prefix(Self.historyLimit)) }
        encode(items, forKey: Self.receivedHistoryKey)
    }

    // MARK: - Incoming fetch high-water mark (shared with the service extension)

    private static let lastDrawingFetchKey = "lastDrawingFetch"

    /// When the last incoming-drawings fetch reached. Lives in the App Group so the
    /// app and the notification service extension share one clock; migrates the old
    /// standard-defaults value on first read. The extension deliberately never
    /// ADVANCES it — the app's fetch remains the source of truth, and the
    /// idempotent saveReceived absorbs the overlap.
    var lastDrawingFetch: Date? {
        get {
            if let date = defaults?.object(forKey: Self.lastDrawingFetchKey) as? Date { return date }
            if let legacy = UserDefaults.standard.object(forKey: Self.lastDrawingFetchKey) as? Date {
                defaults?.set(legacy, forKey: Self.lastDrawingFetchKey)
                UserDefaults.standard.removeObject(forKey: Self.lastDrawingFetchKey)
                return legacy
            }
            return nil
        }
        nonmutating set { defaults?.set(newValue, forKey: Self.lastDrawingFetchKey) }
    }

    /// Newest-first list of dotdots you sent.
    func sentHistory() -> [SentMessage] {
        decode([SentMessage].self, forKey: Self.sentHistoryKey) ?? []
    }

    /// Record a send for the inbox's "sent" feed. Called once per send (online or
    /// offline) from `AppModel.send`, so it captures every dot/photo/doodle.
    func appendSent(_ message: SentMessage) {
        var items = sentHistory()
        items.insert(message, at: 0)
        if items.count > Self.historyLimit { items = Array(items.prefix(Self.historyLimit)) }
        encode(items, forKey: Self.sentHistoryKey)
    }

    /// Advance a sent message's delivery state (the sent tab is the honest record;
    /// the composer's "sent!" flip is optimistic).
    func updateSentStatus(id: String, status: SentMessage.SendStatus,
                          failedRecipientIDs: [String] = []) {
        var items = sentHistory()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        items[index].failedRecipientIDs = failedRecipientIDs
        encode(items, forKey: Self.sentHistoryKey)
    }

    // MARK: - Reactions

    /// Record MY reaction to a received dotdot (nil = un-react) everywhere that
    /// drawing lives: the received feed, the sender's per-friend widget slot, and the
    /// latest-from-anyone slot — so the widget badge and the tray stay in step.
    /// Matched by (senderID, sentAt): the stable identity of a received dotdot.
    func applyMyReaction(_ emoji: String?, senderID: String, sentAt: Date) {
        func stamped(_ d: DisplayDrawing) -> DisplayDrawing {
            guard d.senderID == senderID, d.sentAt == sentAt else { return d }
            var updated = d
            updated.myReaction = emoji
            return updated
        }
        encode(receivedHistory().map(stamped), forKey: Self.receivedHistoryKey)
        if let slot = decode(DisplayDrawing.self, forKey: Self.friendDisplayKey(senderID)) {
            encode(stamped(slot), forKey: Self.friendDisplayKey(senderID))
        }
        if let latest = decode(DisplayDrawing.self, forKey: Self.latestReceivedKey) {
            encode(stamped(latest), forKey: Self.latestReceivedKey)
        }
    }

    /// Attach a friend's reaction to the dotdot I sent (the sent feed). Matched by
    /// `messageID` when the drawing carried one; otherwise the nearest sent-time
    /// within a small tolerance (dotdots sent before messageID shipped). One
    /// reaction per person — a newer one replaces theirs.
    func applyIncomingReaction(_ reaction: ReactionInfo, messageID: String?, drawingSentAt: Date) {
        var items = sentHistory()
        let index: Int?
        if let messageID, let exact = items.firstIndex(where: { $0.id == messageID }) {
            index = exact
        } else {
            index = items.indices
                .filter { abs(items[$0].sentAt.timeIntervalSince(drawingSentAt)) < 5 }
                .min { abs(items[$0].sentAt.timeIntervalSince(drawingSentAt))
                     < abs(items[$1].sentAt.timeIntervalSince(drawingSentAt)) }
        }
        guard let index else { return }   // scrolled out of the capped history — drop
        items[index].reactions.removeAll { $0.reactorID == reaction.reactorID }
        items[index].reactions.insert(reaction, at: 0)
        encode(items, forKey: Self.sentHistoryKey)
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

    // MARK: - Debug widget override (visual QA from the debug panel)

    private static let debugWidgetOverrideKey = "debug.widgetOverride"

    /// Wrapper so the panel can preview the EMPTY state too: key absent = no
    /// override (live data); present with `drawing == nil` = preview empty.
    struct WidgetDebugOverride: Codable {
        var drawing: DisplayDrawing?
    }

    /// When set (from the debug panel), widget providers render this instead of
    /// live data. The real slots are untouched, so clearing the override
    /// restores the live widget instantly.
    func widgetDebugOverride() -> WidgetDebugOverride? {
        decode(WidgetDebugOverride.self, forKey: Self.debugWidgetOverrideKey)
    }

    func setWidgetDebugOverride(_ override: WidgetDebugOverride?) {
        guard let override else {
            defaults?.removeObject(forKey: Self.debugWidgetOverrideKey)
            return
        }
        encode(override, forKey: Self.debugWidgetOverrideKey)
    }

    // MARK: - Reset (iCloud account switch starts fresh)

    func clearSharedState() {
        guard let defaults else { return }
        for key in [Self.localEchoKey, Self.latestReceivedKey, Self.rosterKey, Self.profileKey,
                    Self.outboxKey, Self.receivedHistoryKey, Self.sentHistoryKey, Self.latestReceivedAtKey,
                    Self.lastDrawingFetchKey, Self.debugWidgetOverrideKey] {
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
