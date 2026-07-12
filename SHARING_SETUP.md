# DOTDOT — Sharing layer setup

The sharing code is built and compiles. CloudKit can't be exercised from a build
machine — it needs real devices, iCloud accounts, and a CloudKit container with a
schema. This file lists the one-time setup to make the cross-device loop work.

## 1. Capabilities (Signing & Capabilities tab, "Dot Grid" target)

Automatic signing will register these on the App ID the first time you add them:

- **iCloud → CloudKit**, container `iCloud.com.kolteaditya.dotgrid`
- **Push Notifications**
- **Background Modes → Remote notifications**
- **App Groups** → `group.com.kolteaditya.dotgrid` (already present)

The entitlements file (`Dot Grid/DotGrid.entitlements`) and `Info.plist`
(`UIBackgroundModes`) are already wired; adding the capabilities in Xcode just
makes the provisioning profile match. The widget target only needs the App Group
(no CloudKit/push).

> `aps-environment` is set to `development`. Xcode flips this for TestFlight/App
> Store automatically; if you build Release for distribution, confirm it's
> `production`.

## 2. CloudKit Dashboard schema (PUBLIC database)

Development environment auto-creates record types on first save, but you MUST add
indexes by hand (CloudKit doesn't infer them). In the Dashboard → Schema → Indexes:

| Record type | Field         | Index                |
|-------------|---------------|----------------------|
| Friendship  | members       | Queryable            |
| InviteCode  | code          | Queryable            |
| Drawing     | recipientID   | Queryable            |
| Drawing     | senderID      | Queryable            |
| Drawing     | sentAt        | Queryable + Sortable |
| Drawing     | recordName    | Queryable (default)  |
| Reaction    | recipientID   | Queryable            |
| Reaction    | reactorID     | Queryable            |
| Reaction    | sentAt        | Queryable + Sortable |
| Reaction    | recordName    | Queryable (default)  |

> `senderID` needs a Queryable index now too — "delete my data" queries drawings
> by sender to remove the ones you sent. `Reaction.reactorID` is likewise only
> for "delete my data".

Fields per type (auto-created on first write; types shown for reference):

- **Profile** — recordName = the user's CloudKit user-record name. `name` (String),
  `tokenSymbol` (String), `tokenColor` (Int64).
- **Friendship** — recordName = `pair_<idA>__<idB>` (sorted, so it's idempotent).
  `members` (List<String>), `userA`, `userB`.
- **InviteCode** — `code` (String), `ownerID` (String), `expiresAt` (Date/Time),
  `used` (Int64), `usedBy` (String).
- **Drawing** — `recipientID`, `senderID`, `senderName`, `tokenSymbol` (String),
  `tokenColor` (Int64), `sentAt` (Date/Time), `kind` (String: "dots"|"photo"),
  `gridData` (Bytes, ~1 KB JSON, dots only), `imageAsset` (Asset, photo only —
  an already-downscaled widget-safe JPEG), `messageID` (String — the sender's
  send UUID; the key a reaction points back at; no index needed).
- **Reaction** — recordName = `reaction-<reactor>-<messageID>` (deterministic, so
  re-reacting replaces and un-reacting deletes). `emoji` (String), `recipientID`
  (String — the original sender, who fetches it), `reactorID`, `reactorName`
  (String), `messageID` (String), `drawingSentAt` (Date/Time — fallback join for
  pre-messageID dotdots), `sentAt` (Date/Time — bumped on every save so
  replacements clear the fetch high-water mark).

> **Photo mode:** a photo message sets `kind="photo"` and uploads the framed image
> as a CKAsset in `imageAsset`. The image is downscaled + JPEG-compressed to
> ~widget pixel size BEFORE upload, so the widget never loads full-res. No new
> index is needed for the photo fields (queries still use recipientID + sentAt).
> No second widget kind — the single systemLarge widget renders dots or photo by
> the stored `kind`.

The push subscriptions (`CKQuerySubscription`s on `Drawing`, `Friendship`, and
`Reaction` — the reaction one also fires on record UPDATE, since re-reacting
mutates the same record) are created from code on first launch — no Dashboard step.

> Tip: run each app flow once in development so the record types appear, then add
> the indexes, then re-run. Deploy the schema to Production before shipping.

## 3. Pairing is code-only

Pairing is by 6-digit code only — there is no invite link or `dotdot.app`
domain. Your code is generated once, persisted on your device, and shown for
**6 hours** (it's reusable within that window, so you can share it with several
pals). Generate/share it in Settings or Add a friend (copy, or the share-sheet
button); the other person types it in under Add a friend.

## 4. What's verified vs. what needs two devices

- ✅ Builds and runs; signed-out boot shows the local composer + an "iCloud" banner
  and still draws locally (foundation pipe intact).
- ✅ Local App Group → widget pipe (drawing is written to the shared container the
  widget reads).
- ⏳ Needs two devices + two iCloud accounts + the schema above: onboarding,
  code pairing, send → friend's widget with the sender's token. This is the
  spec's "DONE WHEN" and can only be confirmed on hardware.

## 5. Architecture (where to look)

- `Shared/GridStore.swift` — the single App Group seam (composer canvas, widget
  display latest + per-friend, roster, profile cache, offline outbox). The widget
  reads only this.
- `Shared/SharedModels.swift`, `Shared/TokenBadge.swift` — Codable models + token UI.
- `Dot Grid/SharingService.swift` — all CloudKit (identity, profile, pairing, send,
  fetch, subscription) with the edge-case handling.
- `Dot Grid/AppModel.swift` — orchestration: iCloud state, account-switch, friends,
  local-first send + offline queue, push/foreground refresh.
- `Dot Grid/RootView.swift` / `OnboardingView` / `AddFriendView` /
  `RecipientPickerView` — the UI.
- `Dot Grid/AppDelegate.swift` — remote-notification registration + push handling.
- `DotGridWidget/DotGridWidget.swift` — default (latest) + per-friend widgets.
