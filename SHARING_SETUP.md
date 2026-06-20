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
(`UIBackgroundModes`, `dotdot` URL scheme) are already wired; adding the
capabilities in Xcode just makes the provisioning profile match. The widget target
only needs the App Group (no CloudKit/push).

> `aps-environment` is set to `development`. Xcode flips this for TestFlight/App
> Store automatically; if you build Release for distribution, confirm it's
> `production`.

## 2. CloudKit Dashboard schema (PUBLIC database)

Development environment auto-creates record types on first save, but you MUST add
indexes by hand (CloudKit doesn't infer them). In the Dashboard → Schema → Indexes:

| Record type | Field         | Index                |
|-------------|---------------|----------------------|
| Profile     | inviteToken   | Queryable            |
| Friendship  | members       | Queryable            |
| InviteCode  | code          | Queryable            |
| Drawing     | recipientID   | Queryable            |
| Drawing     | sentAt        | Queryable + Sortable |
| Drawing     | recordName    | Queryable (default)  |

Fields per type (auto-created on first write; types shown for reference):

- **Profile** — recordName = the user's CloudKit user-record name. `name` (String),
  `tokenSymbol` (String), `tokenColor` (Int64), `inviteToken` (String).
- **Friendship** — recordName = `pair_<idA>__<idB>` (sorted, so it's idempotent).
  `members` (List<String>), `userA`, `userB`.
- **InviteCode** — `code` (String), `ownerID` (String), `expiresAt` (Date/Time),
  `used` (Int64), `usedBy` (String).
- **Drawing** — `recipientID`, `senderID`, `senderName`, `tokenSymbol` (String),
  `tokenColor` (Int64), `sentAt` (Date/Time), `kind` (String: "dots"|"photo"),
  `gridData` (Bytes, ~1 KB JSON, dots only), `imageAsset` (Asset, photo only —
  an already-downscaled widget-safe JPEG).

> **Photo mode:** a photo message sets `kind="photo"` and uploads the framed image
> as a CKAsset in `imageAsset`. The image is downscaled + JPEG-compressed to
> ~widget pixel size BEFORE upload, so the widget never loads full-res. No new
> index is needed for the photo fields (queries still use recipientID + sentAt).
> No second widget kind — the single systemLarge widget renders dots or photo by
> the stored `kind`.

The push subscription (`CKQuerySubscription` on `Drawing` where
`recipientID == me`) is created from code on first launch — no Dashboard step.

> Tip: run each app flow once in development so the record types appear, then add
> the indexes, then re-run. Deploy the schema to Production before shipping.

## 3. Invite links (optional, out of MVP scope)

The shareable link is `https://dotdot.app/i/<inviteToken>`. For a tapped link to
*open the app* (and hit the App Store when not installed) you need a real domain
with an `apple-app-site-association` file and the Associated Domains capability —
deliberately out of scope here. **The 6-digit code path works today** and is the
reliable way to pair while testing. The app already parses both the `https` link
and the `dotdot://invite?t=<token>` custom scheme via `AppModel.inviteToken(from:)`.

## 4. What's verified vs. what needs two devices

- ✅ Builds and runs; signed-out boot shows the local composer + an "iCloud" banner
  and still draws locally (foundation pipe intact).
- ✅ Local App Group → widget pipe (drawing is written to the shared container the
  widget reads).
- ⏳ Needs two devices + two iCloud accounts + the schema above: onboarding,
  code/link pairing, send → friend's widget with the sender's token. This is the
  spec's "DONE WHEN" and can only be confirmed on hardware.

## 5. Architecture (where to look)

- `Shared/GridStore.swift` — the single App Group seam (composer canvas, widget
  display latest + per-friend, roster, profile cache, offline outbox). The widget
  reads only this.
- `Shared/SharedModels.swift`, `Shared/TokenBadge.swift` — Codable models + token UI.
- `Dot Grid/SharingService.swift` — all CloudKit (identity, profile, pairing, send,
  fetch, subscription) with the edge-case handling.
- `Dot Grid/AppModel.swift` — orchestration: iCloud state, account-switch, friends,
  local-first send + offline queue, push/foreground refresh, invite handling.
- `Dot Grid/RootView.swift` / `OnboardingView` / `AddFriendView` /
  `RecipientPickerView` — the UI.
- `Dot Grid/AppDelegate.swift` — remote-notification registration + push handling.
- `DotGridWidget/DotGridWidget.swift` — default (latest) + per-friend widgets.
