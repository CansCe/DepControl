# DepControl brand assets

The mark is a dependency tree with one node picked out. That asymmetry is the
product — the app exists to find the one leaf that matters — and it is what
keeps this from being a generic node-and-edge graph. It also survives being
shrunk, which a detailed graph does not.

## Files

| File | Use |
|------|-----|
| `depcontrol-icon.svg` | Source of truth for the icon. Filled tile — holds its silhouette at 16px. |
| `depcontrol-icon-512.png` | **Upload this to the GitHub OAuth app.** Also the Android icon on API 24–25, which predates adaptive icons. |
| `depcontrol-icon-foreground.svg` | Android adaptive icon, foreground layer. Mark only, no tile — the launcher draws the tile. |
| `depcontrol-icon-monochrome.svg` | Android 13+ themed icon. Flat silhouette; the launcher tints it to the wallpaper. |
| `depcontrol-icon-foreground-1024.png`, `depcontrol-icon-monochrome-1024.png` | Exports of the two above. `flutter_launcher_icons` reads these — it does not read SVG. |
| `depcontrol-mark.svg` | Mark alone on light backgrounds: docs, README, app bar. |
| `depcontrol-logo.svg` | Horizontal lockup for light backgrounds. |
| `depcontrol-logo-dark.svg` | Lockup for dark backgrounds. The mark goes white — `#0553B1` on dark is below a readable contrast ratio. |
| `export-png.html` | Re-export PNGs at any size after changing the artwork. Runs offline in a browser. |

## Already wired into the app

`flutter build web` picks these up with no extra step — verified against a real
release build:

```
frontend/web/favicon.svg                     # sharp at any size
frontend/web/favicon-16.png, favicon-32.png  # older browsers
frontend/web/apple-touch-icon.png            # iOS home screen
frontend/web/icons/Icon-{192,512}.png        # installable web app
frontend/web/icons/Icon-maskable-{192,512}.png
frontend/web/manifest.json                   # name, colours, icon list
```

The maskable variants are a separate file rather than the same art reused. An
Android maskable icon can be cropped to a circle of 80% diameter, and the mark
at full size sits just outside that — so the maskable pair is drawn at 78% with
the tile bled to the edges, leaving the corners expendable.

Android is wired up too, through
[`flutter_launcher_icons`](https://pub.dev/packages/flutter_launcher_icons) —
configured at the bottom of `frontend/pubspec.yaml`, run by hand, output checked
in. A normal `flutter build apk` does not run it:

```
frontend/android/app/src/main/res/mipmap-{m,h,x,xx,xxx}hdpi/ic_launcher.png
frontend/android/app/src/main/res/drawable-{m,h,x,xx,xxx}hdpi/ic_launcher_foreground.png
frontend/android/app/src/main/res/drawable-{m,h,x,xx,xxx}hdpi/ic_launcher_monochrome.png
frontend/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml
frontend/android/app/src/main/res/values/colors.xml     # ic_launcher_background
```

The adaptive layers are drawn to fill their canvas rather than to fit inside the
mask's safe zone, because the generator adds a 16% inset of its own — the
reasoning, and the numbers that follow from it, are in the comment at the top of
`depcontrol-icon-foreground.svg`. There is no iOS or desktop target in this repo;
`ios: false` says so explicitly so that adding one is a decision rather than an
oversight.

## Palette

| Colour | Hex | Role |
|--------|-----|------|
| Dart blue | `#0553B1` | Primary. Already the app's `colorSchemeSeed`, so the logo and the UI agree rather than clashing by a few degrees of hue. |
| Amber | `#F59E0B` | The flagged node — the only warm element in the mark. |
| Slate | `#1F2937` | Wordmark on light backgrounds. |

The amber echoes the severity language in the report without being any one
severity colour, so the logo does not accidentally claim a finding is "medium".

## Setting the GitHub OAuth app logo

GitHub wants a raster image of at least 200×200 and will not accept an SVG, so
`depcontrol-icon-512.png` is checked in ready to upload.

1. **Settings → Developer settings → OAuth Apps**, pick the app.
2. Upload `brand/depcontrol-icon-512.png` under *Application logo*.

The badge is a filled tile, so it reads on GitHub's light and dark themes
without needing a second variant.

## If you change the artwork

The wordmark in the lockups is **live text**, rendered with whatever font the
viewer has. That is fine inside this repo. Convert it to outlines before the
logo goes anywhere you do not control the rendering — a store listing, a
printed asset, someone else's site.

The icon is also inlined in `export-png.html` so that file works offline. Edit
`depcontrol-icon.svg` and paste the same change there.

The two adaptive layers repeat the mark's geometry rather than importing it, so
a change to the mark has to be made in all three SVGs. Then re-export the pair
and regenerate the Android set — headless Chrome does the rasterising, since the
PNGs need an alpha channel that `export-png.html`'s canvas path does not give
you for free:

```bash
chrome --headless --default-background-color=00000000 --window-size=1024,1024 --screenshot=out.png icon.svg
```

The SVGs declare `width="108"`, so bump that to `1024` in a scratch copy before
shooting — Chrome renders a standalone SVG at its intrinsic size and the window
only crops. Then from `frontend/`:

```bash
dart run flutter_launcher_icons
```
