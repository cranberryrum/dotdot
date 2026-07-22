# Dotdot App Store screenshots

The final 6.9-inch iPhone set is in `Final/`. Every upload frame is an opaque RGB PNG at 1320 × 2868 pixels.

## Story order

1. **tiny moments. right on their home screen.** — the real production widget on an iOS Home Screen
2. **draw a tiny hello.** — the 8 × 8 dots composer
3. **send the whole moment.** — photo, dual shot, caption, and location
4. **scribble it your way.** — the native doodle composer
5. **see it. react. send one back.** — sent history and friend reactions

## Files

- `Final/00-contact-sheet.png` — presentation preview only
- `Final/01-home-screen.png` through `Final/05-react.png` — App Store upload files
- `Captures/` — the five authentic simulator sources used in the compositions
- `Assets/` — rights-safe generated friendship photos used only in the staged photo capture
- `RenderAppStore.swift` — editable layout, copy, colors, typography, and export logic

## Regenerate

Run from the repository root:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/dotdot-clang-cache \
  SWIFT_MODULECACHE_PATH=/tmp/dotdot-swift-cache \
  xcrun swift AppStore/RenderAppStore.swift
```

## Generated photo sources

The built-in ImageGen tool produced both source images. They contain no third-party logos, interface imagery, or identifiable public figures.

- Main photo prompt: “Photorealistic-natural square in-app photo of three Indian friends, all clearly 21+, laughing together on a Bandra rooftop at golden hour; authentic smartphone image with warm candid energy, realistic skin and clothing, no logos, text, or watermark.”
- Dual-shot prompt: “Identity-preserving companion photo based on the main image, showing the same woman making a peace sign on the same rooftop in the same golden-hour light; square selfie/PIP composition, authentic smartphone image, no logos, text, or watermark.”
