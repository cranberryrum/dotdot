# DOTDOT — design spec (native translation)

This is the SwiftUI translation of the "rad" Claude Design comp. Match these tokens
and motion values. Do NOT port the prototype's HTML or CSS directly; rebuild it
natively to these values. Keep a screenshot of the comp in the repo next to this
file as the visual ground truth.

## Colors

Loud chrome palette (used for accents, lit dots, marketing/chrome surfaces):

| Token  | Hex      |
|--------|----------|
| blue   | #2E6BFF  |
| pink   | #FF5FA6  |
| lime   | #CFF000  |
| red    | #FF3A1E  |
| yellow | #FFC400  |
| mint   | #3FE0A2  |
| peri   | #7C86FF  |
| cream  | #FFF3D6  |

Dark editor surfaces:

| Token     | Hex      | Use                          |
|-----------|----------|------------------------------|
| ink       | #0B0B0D  | app / editor background      |
| panel     | #141417  | the grid panel surface       |
| cell-off  | #1E1E22  | empty dot fill               |
| cell-rim  | #28282E  | subtle rim around empty dots |

Define these once as a Color extension or in the asset catalog. The accent palette
is what dots light up in, picked in the composer.

## Fonts

All four are Google Fonts under the SIL Open Font License, free to bundle in the app.
Add the .ttf files to the project and remember the `.custom()` string is the
PostScript name, not the filename.

| Role        | Font          | Use                                            |
|-------------|---------------|------------------------------------------------|
| bubble      | Bagel Fat One | the DOTDOT wordmark, big playful display        |
| heavy       | Archivo Black | heavy headings, loud labels                     |
| ui          | Hanken Grotesk| body and general UI text                        |
| mono        | Space Mono    | metadata labels (e.g. "12X12 CANVAS", "44 DOTS")|

## Surfaces and the dot

- App background: ink (#0B0B0D).
- Grid panel: panel (#141417), generously rounded corners.
- Empty dot: cell-off fill (#1E1E22) with a 1px-ish rim in cell-rim (#28282E).
- Lit dot: filled in the chosen accent color, with a neon glow (below).

## The neon glow (signature effect)

The lit dots bloom. In SwiftUI, stack two colored shadows on the filled shape, a tight
bright one and a wider soft one:

```swift
Circle()
    .fill(accent)
    .shadow(color: accent.opacity(0.85), radius: 4)
    .shadow(color: accent.opacity(0.55), radius: 12)
```

Tune the radii to taste. Widget caveat: glow and blur render more heavily (and
sometimes differently) inside a widget than in the app, so prototype the lit-dot glow
on the actual widget early and dial it back there if it muddies. The widget is the
surface that has to read clearly.

## Decorative chrome (not the editor)

These belong to the bright marketing/onboarding layer, not the dark editor screen:

- Halftone dot field: a polka background, `radial-gradient(currentColor 28%,
  transparent 30%)` tiled at 22px. In SwiftUI, draw it with a tiled Canvas of small
  dots on a 22pt grid, tinted to the surface. Great for onboarding and empty states.
- Scalloped / wavy edge (the blob-input look): build as a custom SwiftUI `Shape` with
  a repeating semicircle top edge. Optional flourish.
- Marquee strip ("DRAW · SEND · REPEAT"): a horizontally scrolling row, translateX 0
  to -50% looped. Decorative.

## Motion (the juice)

Exact curves from the comp. For the multi-stop ones, `keyframeAnimator` (iOS 17+) maps
these directly; for the simple overshoots, a spring is cleaner.

| Name        | Spec                                                        | SwiftUI                                  |
|-------------|-------------------------------------------------------------|------------------------------------------|
| dotpop      | scale .35 → 1.22 → 1                                         | spring(response .3, damping .5) on place |
| dotpoof     | scale 1 → .2, opacity 1 → 0                                  | clear / remove transition                |
| drawin      | scale 0 → 1, opacity 0 → 1                                   | stamp / reveal fill-in                   |
| popin       | scale 0 (rot -12) → 1.18 (rot 4) → 1 (rest)                  | element entrance with rotational overshoot |
| ripple      | scale .3 → 2.6, opacity .55 → 0                              | tap feedback ring                        |
| launchUp    | y 0 → -18px (s1.06, r-2) → -140% (s.18, r8), opacity → 0     | the send animation                       |
| throb       | scale 1 → 1.045 (loop)                                       | idle "breathing" on lit dots / widget    |
| floaty      | translate + rotate drift (loop)                             | floating sparkles / stickers             |
| wobble      | rotate around rest (loop)                                   | sticker idle                             |
| spin        | rotate 360 (loop)                                           | loaders                                  |
| confetti    | y -30 → 700px, rotate 0 → 640                               | send celebration                         |
| sheetup     | translateY 102% → 0                                          | bottom sheet entrance                    |
| flashpop    | scale .6 → 1.1 → 1, opacity in                              | badge / toast pop                        |
| hapticflash | opacity 0 → .9 → 0                                           | quick visual flash synced to a haptic    |

Notes:
- `launchUp` is the send juice. Pair it with the earlier decision to NOT clear the
  board: let a flying copy launch up and shrink away while the actual drawing stays.
- `throb` is the living-pixel idle breath. Keep it on the widget, keep it off the
  composer (it competes with drawing there).

## Reminders
- Match these tokens; do not translate the HTML.
- Corner radii are not pinned here; match the comp's generous rounding (panels read
  around 16 to 20pt, chips much rounder). Treat these as starting values.
- Glow and the halftone are heavier in widgets. Validate both at true widget size.
