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
    private static let localEchoKey = "localEcho"       // legacy key retained for upgrade/reset compatibility
    private static let localEchoUpdatedAtKey = "localEchoUpdatedAt.v2"
    private static let latestReceivedKey = "latestReceived"
    private static let latestReceivedUpdatedAtKey = "latestReceivedUpdatedAt.v2"
    private static let rosterKey = "friendRoster"
    private static let profileKey = "myProfile"
    private static let outboxKey = "outbox"
    private static let receivedHistoryKey = "receivedHistory"   // inbox: dotdots from others
    private static let sentHistoryKey = "sentHistory"           // inbox: dotdots you sent
    private static let latestReceivedAtKey = "latestReceivedAt" // unread check (a Date, no blob)
    private static let latestReceivedIngestedAtKey = "latestReceivedIngestedAt.v2"
    private static let pendingIncomingRecordNamesKey = "pendingIncomingRecordNames"
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

    /// Legacy writer retained for stored-state compatibility. Live sends no longer
    /// call this because widgets intentionally show received friend content only.
    func saveLocalEcho(_ drawing: DisplayDrawing) {
        encode(drawing, forKey: Self.localEchoKey)
        defaults?.set(Date(), forKey: Self.localEchoUpdatedAtKey)
    }

    /// A drawing received from a friend. Every projection is monotonic: a late
    /// lookback result can fill its true feed position but can never roll either
    /// widget slot back to older content. Returns true only for a genuinely new
    /// inbox row, so callers don't announce/reload duplicate push deliveries.
    @discardableResult
    func saveReceived(_ drawing: DisplayDrawing) -> Bool {
        let inserted = insertReceivedHistory(drawing)

        if let current = decode(DisplayDrawing.self, forKey: Self.friendDisplayKey(drawing.senderID)) {
            if Self.prefersForWidget(drawing, over: current) {
                encode(drawing, forKey: Self.friendDisplayKey(drawing.senderID))
            }
        } else {
            encode(drawing, forKey: Self.friendDisplayKey(drawing.senderID))
        }

        if let current = decode(DisplayDrawing.self, forKey: Self.latestReceivedKey) {
            if Self.prefersForWidget(drawing, over: current) {
                encode(drawing, forKey: Self.latestReceivedKey)
                defaults?.set(Date(), forKey: Self.latestReceivedUpdatedAtKey)
            }
        } else {
            encode(drawing, forKey: Self.latestReceivedKey)
            defaults?.set(Date(), forKey: Self.latestReceivedUpdatedAtKey)
        }

        // Unread is based on when THIS device first ingested a new row, never on
        // an untrusted sender clock. Duplicate app/extension deliveries don't
        // resurrect an already-seen message.
        if inserted { defaults?.set(Date(), forKey: Self.latestReceivedIngestedAtKey) }
        return inserted
    }

    /// When the newest received dotdot arrived, or nil if none. A plain Date, so the
    /// unread check stays cheap (no image decode). Forward-only: dotdots received
    /// before this shipped don't count.
    func latestReceivedAt() -> Date? {
        defaults?.object(forKey: Self.latestReceivedIngestedAtKey) as? Date
    }

    /// What every unconfigured/default widget shows: the newest dotdot received
    /// from a friend. Outgoing local echoes intentionally never participate.
    func latestReceivedDrawing() -> DisplayDrawing? {
        Self.defaultWidgetDrawing(
            received: decode(DisplayDrawing.self, forKey: Self.latestReceivedKey)
        )
    }

    nonisolated static func defaultWidgetDrawing(received: DisplayDrawing?) -> DisplayDrawing? {
        received
    }

    /// A total ordering for widget projections. CloudKit creation dates can tie,
    /// so record/message identity breaks the tie deterministically instead of a
    /// strict date comparison leaving one widget family on an older record.
    nonisolated static func prefersForWidget(_ candidate: DisplayDrawing,
                                             over current: DisplayDrawing) -> Bool {
        if candidate.orderingDate != current.orderingDate {
            return candidate.orderingDate > current.orderingDate
        }
        return widgetIdentity(candidate) > widgetIdentity(current)
    }

    private nonisolated static func widgetIdentity(_ drawing: DisplayDrawing) -> String {
        drawing.recordName
            ?? drawing.messageID
            ?? senderTimeKey(senderID: drawing.senderID, sentAt: drawing.sentAt)
    }

    nonisolated static func newestForWidget(in drawings: [DisplayDrawing]) -> DisplayDrawing? {
        drawings.reduce(nil) { current, candidate in
            guard let current else { return candidate }
            return prefersForWidget(candidate, over: current) ? candidate : current
        }
    }

    /// Repair the lightweight widget slots from the canonical received feed.
    /// This closes the app/notification-extension race where the history write
    /// succeeds but a process is suspended before its projection/reload finishes.
    /// Callers run this in the app before asking WidgetKit for fresh timelines;
    /// the widget itself stays cheap and decodes only one drawing.
    @discardableResult
    func repairReceivedWidgetProjections() -> Bool {
        let history = receivedHistory()
        guard !history.isEmpty else { return false }

        var changed = false
        if let newest = Self.newestForWidget(in: history) {
            let current = decode(DisplayDrawing.self, forKey: Self.latestReceivedKey)
            if current.map({ Self.prefersForWidget(newest, over: $0) }) ?? true {
                encode(newest, forKey: Self.latestReceivedKey)
                defaults?.set(Date(), forKey: Self.latestReceivedUpdatedAtKey)
                changed = true
            }
        }

        var newestBySender: [String: DisplayDrawing] = [:]
        for drawing in history {
            if let current = newestBySender[drawing.senderID],
               !Self.prefersForWidget(drawing, over: current) {
                continue
            }
            newestBySender[drawing.senderID] = drawing
        }
        for (senderID, newest) in newestBySender {
            let key = Self.friendDisplayKey(senderID)
            let current = decode(DisplayDrawing.self, forKey: key)
            if current.map({ Self.prefersForWidget(newest, over: $0) }) ?? true {
                encode(newest, forKey: key)
                changed = true
            }
        }
        return changed
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

    /// The sender+time identity of a received dotdot — the pre-messageID key.
    /// One implementation shared by the dedupe pass and the fetch layer's
    /// already-have check, so their notions of "same drawing" can't drift.
    nonisolated static func senderTimeKey(senderID: String, sentAt: Date) -> String {
        "\(senderID)|\(sentAt.timeIntervalSinceReferenceDate)"
    }

    /// Identity sets for everything already received — lets the fetch layer skip
    /// records it has BEFORE downloading their assets.
    func receivedIdentities() -> (recordNames: Set<String>, messageIDs: Set<String>, senderTimes: Set<String>) {
        var recordNames = Set<String>()
        var messageIDs = Set<String>()
        var senderTimes = Set<String>()
        for drawing in receivedHistory() {
            if let name = drawing.recordName { recordNames.insert(name) }
            if let id = drawing.messageID { messageIDs.insert(id) }
            senderTimes.insert(Self.senderTimeKey(senderID: drawing.senderID, sentAt: drawing.sentAt))
        }
        return (recordNames, messageIDs, senderTimes)
    }

    /// Collapse twins — same messageID, or same sender + exact sentAt (the
    /// pre-messageID identity, which also catches a refetched old drawing whose
    /// stored copy predates messageID). Keeps the first (newest) copy, but never
    /// loses a reaction stamped on a later twin.
    nonisolated static func dedupingReceived(_ items: [DisplayDrawing]) -> [DisplayDrawing] {
        var kept: [DisplayDrawing] = []
        var indexByRecordName: [String: Int] = [:]
        var indexByMessageID: [String: Int] = [:]
        var indexBySenderTime: [String: Int] = [:]
        for item in items {
            let timeKey = senderTimeKey(senderID: item.senderID, sentAt: item.sentAt)
            let twin = item.recordName.flatMap { indexByRecordName[$0] }
                ?? item.messageID.flatMap { indexByMessageID[$0] }
                ?? indexBySenderTime[timeKey]
            if let twin {
                if kept[twin].myReaction == nil { kept[twin].myReaction = item.myReaction }
                if kept[twin].recordName == nil { kept[twin].recordName = item.recordName }
                if kept[twin].serverCreatedAt == nil { kept[twin].serverCreatedAt = item.serverCreatedAt }
                continue
            }
            if let recordName = item.recordName { indexByRecordName[recordName] = kept.count }
            if let messageID = item.messageID { indexByMessageID[messageID] = kept.count }
            indexBySenderTime[timeKey] = kept.count
            kept.append(item)
        }
        return kept
    }

    /// Where a drawing belongs in the newest-first feed. A record re-fetched by
    /// the lookback window after falling out of the capped history lands at its
    /// true position (or straight off the trimmed end) — never at the top.
    nonisolated static func insertionIndex(for drawing: DisplayDrawing, in items: [DisplayDrawing]) -> Int {
        items.firstIndex { $0.orderingDate <= drawing.orderingDate } ?? items.endIndex
    }

    private func insertReceivedHistory(_ drawing: DisplayDrawing) -> Bool {
        var items = receivedHistory()
        // Idempotent: the notification service extension AND the app's fetch paths
        // can both deliver the same record — the second arrival is a no-op (which
        // also preserves any reaction already attached locally). Matched by
        // messageID OR sender+time, so a stored copy that predates messageID
        // still counts as the same drawing.
        let duplicateIndex = items.firstIndex { existing in
            if let recordName = drawing.recordName, existing.recordName == recordName { return true }
            if let messageID = drawing.messageID, existing.messageID == messageID { return true }
            return existing.senderID == drawing.senderID && existing.sentAt == drawing.sentAt
        }
        if let duplicateIndex {
            // Upgrade a legacy cached row with its exact server identity/clock.
            var existing = items[duplicateIndex]
            var changed = false
            if existing.recordName == nil, drawing.recordName != nil {
                existing.recordName = drawing.recordName
                changed = true
            }
            if existing.serverCreatedAt == nil, drawing.serverCreatedAt != nil {
                existing.serverCreatedAt = drawing.serverCreatedAt
                changed = true
            }
            if changed {
                items[duplicateIndex] = existing
                encode(items, forKey: Self.receivedHistoryKey)
            }
            return false
        }
        items.insert(drawing, at: Self.insertionIndex(for: drawing, in: items))
        if items.count > Self.historyLimit { items = Array(items.prefix(Self.historyLimit)) }
        encode(items, forKey: Self.receivedHistoryKey)
        return true
    }

    // MARK: - Incoming fetch high-water mark (shared with the service extension)

    private static let lastDrawingFetchKey = "lastDrawingFetch"
    private static let lastDrawingServerFetchKey = "lastDrawingServerFetch.v2"

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

    /// Server-authored high-water mark used by the new receive query. Kept
    /// separate from the legacy sender-clock mark so migration never compares
    /// dates from two different clock domains.
    var lastDrawingServerFetch: Date? {
        get { defaults?.object(forKey: Self.lastDrawingServerFetchKey) as? Date }
        nonmutating set { defaults?.set(newValue, forKey: Self.lastDrawingServerFetchKey) }
    }

    // MARK: - Durable incoming retry queue

    /// Push IDs and metadata discoveries remain here until their full payload is
    /// decoded and committed. A repeatedly failing asset therefore cannot age out
    /// of the reconciliation window and disappear forever.
    func pendingIncomingRecordNames() -> [String] {
        defaults?.stringArray(forKey: Self.pendingIncomingRecordNamesKey) ?? []
    }

    func enqueueIncomingRecordName(_ name: String) {
        guard !name.isEmpty else { return }
        var names = pendingIncomingRecordNames()
        guard !names.contains(name) else { return }
        names.append(name)
        // Defensive bound against a permanently malformed server record set.
        if names.count > 500 { names.removeFirst(names.count - 500) }
        defaults?.set(names, forKey: Self.pendingIncomingRecordNamesKey)
    }

    func finishIncomingRecordName(_ name: String) {
        var names = pendingIncomingRecordNames()
        guard let index = names.firstIndex(of: name) else { return }
        names.remove(at: index)
        defaults?.set(names, forKey: Self.pendingIncomingRecordNamesKey)
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
    @discardableResult
    func applyIncomingReaction(_ reaction: ReactionInfo, messageID: String?, drawingSentAt: Date) -> Bool {
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
        guard let index else { return false }   // scrolled out of the capped history — drop
        if items[index].reactions.first(where: { $0.reactorID == reaction.reactorID }) == reaction {
            return false
        }
        items[index].reactions.removeAll { $0.reactorID == reaction.reactorID }
        items[index].reactions.insert(reaction, at: 0)
        encode(items, forKey: Self.sentHistoryKey)
        return true
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

#if DEBUG
    /// Exact, idempotent histories for simulator marketing captures. Unlike the
    /// append APIs, repeated launches cannot accumulate duplicate cards.
    func setCaptureHistories(received: [DisplayDrawing], sent: [SentMessage]) {
        encode(Array(received.prefix(Self.historyLimit)), forKey: Self.receivedHistoryKey)
        encode(Array(sent.prefix(Self.historyLimit)), forKey: Self.sentHistoryKey)
        if let newest = received.first {
            encode(newest, forKey: Self.latestReceivedKey)
            encode(newest, forKey: Self.friendDisplayKey(newest.senderID))
            defaults?.set(Date(), forKey: Self.latestReceivedUpdatedAtKey)
            defaults?.set(Date(), forKey: Self.latestReceivedIngestedAtKey)
        } else {
            defaults?.removeObject(forKey: Self.latestReceivedKey)
            defaults?.removeObject(forKey: Self.latestReceivedUpdatedAtKey)
            defaults?.removeObject(forKey: Self.latestReceivedIngestedAtKey)
        }
    }
#endif

    // MARK: - Reset (iCloud account switch starts fresh)

    func clearSharedState() {
        guard let defaults else { return }
        // Capture before removing rosterKey; otherwise account switches leave the
        // old per-friend widget slots orphaned in the App Group indefinitely.
        let friendIDs = roster().map(\.id)
        for key in [Self.localEchoKey, Self.latestReceivedKey, Self.rosterKey, Self.profileKey,
                    Self.localEchoUpdatedAtKey, Self.latestReceivedUpdatedAtKey,
                    Self.outboxKey, Self.receivedHistoryKey, Self.sentHistoryKey, Self.latestReceivedAtKey,
                    Self.latestReceivedIngestedAtKey, Self.pendingIncomingRecordNamesKey,
                    Self.lastDrawingFetchKey, Self.lastDrawingServerFetchKey, Self.debugWidgetOverrideKey] {
            defaults.removeObject(forKey: key)
        }
        for id in friendIDs {
            defaults.removeObject(forKey: Self.friendDisplayKey(id))
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
