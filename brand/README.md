# DepControl brand assets

The mark is a dependency tree with one node picked out. That asymmetry is the
product — the app exists to find the one leaf that matters — and it is what
keeps this from being a generic node-and-edge graph. It also survives being
shrunk, which a detailed graph does not.

## Files

| File | Use |
|------|-----|
| `depcontrol-icon.svg` | Source of truth for the icon. Filled tile — holds its silhouette at 16px. |
| `depcontrol-icon-512.png` | **Upload this to the GitHub OAuth app.** |
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

If you add a mobile or desktop target later, point
[`flutter_launcher_icons`](https://pub.dev/packages/flutter_launcher_icons) at
`brand/depcontrol-icon-512.png` and it will generate the platform sets.

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
