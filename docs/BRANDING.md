# Branding — colours & app icon

Everything visual about Liberated Bread comes from two files in
`tool/branding/`:

| File | Owns |
| --- | --- |
| `brand.json` | The palette (hex values) |
| `app_icon_mascot.svg` | The logo artwork |

Everything else — 43 icon files across iOS/macOS/Android/web, the Android
adaptive-icon background, the web manifest colours — is **generated** from
those two. Don't hand-edit generated icons; they get overwritten.

## One-time setup

```bash
cd tool/branding
npm install
```

Node + [sharp](https://sharp.pixelplumbing.com/) are an authoring-only
dependency. Generated icons are committed, so CI and normal Flutter builds
never need this.

## Changing the colours

1. Edit the hex values in `tool/branding/brand.json`.
2. Mirror the same values in `lib/core/theme.dart` (`LiberatedBreadTheme`).
3. Regenerate + verify:

```bash
cd tool/branding && npm run icons
cd ../.. && flutter test test/core/brand_test.dart
```

Step 2 is manual because Dart can't read `brand.json` at compile time — but
it isn't on the honour system: `test/core/brand_test.dart` fails if the theme
constants and `brand.json` disagree, so CI catches the drift.

`npm run icons` also rewrites two files that have to repeat the background
colour outside Dart, so they can't drift either:

- `android/app/src/main/res/values/ic_launcher_background.xml`
- `background_color` / `theme_color` in `web/manifest.json`

If the logo artwork itself uses a colour you changed, update the fills in
`app_icon_mascot.svg` too — the SVG is the artwork master and is not
colour-substituted.

### Foreground colours are derived, not chosen

Don't hardcode a foreground on a brand fill. `LiberatedBreadTheme.onBrand()`
picks one from the background's luminance — the mascot's dark `ink` on light
fills, white on dark ones — so new brand colours stay readable automatically.

This matters more than it looks: white on the turquoise is only **2.38:1** and
on the bread orange **2.37:1**, both under even the 3:1 WCAG floor for UI
graphics. `brand_test.dart` asserts the app bar and scan FAB clear 4.5:1 in
both themes, so a palette change that breaks contrast fails CI rather than
shipping.

## Changing the logo

Two ways, pick whichever matches what you have:

- **Vector** — edit or replace `tool/branding/app_icon_mascot.svg`.
- **Raster** — drop a `tool/branding/app_icon_mascot.png` next to it. If that
  file exists it wins, and the SVG is ignored.

Then `cd tool/branding && npm run icons`.

Requirements for the artwork, either format:

- **Square**, and **cropped tight** to the logo — the generator centres the
  artwork and applies its own padding, so any built-in margin is doubled up.
- **Transparent background.** The artwork is the mascot *only*; the background
  colour comes from `brand.json`. A baked-in background breaks the Android
  adaptive icon, which needs a transparent foreground layer.
- For raster, **1024×1024 or larger** — everything is downscaled from a 1024px
  master.

`app_icon_preview.png` is regenerated each run as a quick visual check.

## Why the generator, instead of `flutter_launcher_icons`

The per-platform rules differ in ways a single source image can't express, and
this script encodes them:

- **iOS** icons are flattened onto the background and stripped of their alpha
  channel — the App Store rejects icons that have one.
- **Android adaptive** foregrounds keep transparency and sit inside the 66%
  safe zone, so the launcher can mask them to any shape.
- **Maskable web** icons use a tighter 56% safe zone for the 80% circle.
- **macOS** art sits inside an inset squircle, per Apple's grid.
- **Android 13+ monochrome** is a flat silhouette derived from the artwork's
  alpha, since themed launchers tint the layer themselves. Face detail
  necessarily drops out — that's inherent to themed icons, not a bug.

## What else follows the brand background

Two things reference `@color/ic_launcher_background` (itself generated from
`brand.json`) rather than repeating the hex, so they track palette changes with
no extra step:

- the Android adaptive-icon background layer, and
- the Android cold-start splash (`res/drawable{,-v21}/launch_background.xml`),
  which would otherwise flash stock white before the app bar paints.
