# MacVoice identity assets

Editable vector masters are in `Assets/`. PNG exports and the macOS icon file are in `Exports/`.

## Files

- `Assets/macvoice-icon-light.svg` — light-surface app icon master.
- `Assets/macvoice-icon-dark.svg` — dark-surface app icon master.
- `Assets/macvoice-symbol.svg` — transparent symbol for compact use.
- `Assets/macvoice-symbol-mono-dark.svg` — monochrome symbol using `currentColor`; set it to the foreground color in the consuming UI.
- `Assets/macvoice-symbol-mono-black.svg` and `Assets/macvoice-symbol-mono-white.svg` — explicit single-color variants.
- `Assets/macvoice-logo-light.svg` and `Assets/macvoice-logo-dark.svg` — horizontal wordmark with “Speak · Type · Done.”
- `Exports/macvoice-icon-light-1024.png`, `Exports/macvoice-icon-dark-1024.png` — full-size icon previews.
- `Exports/macvoice-logo-light.png`, `Exports/macvoice-logo-dark.png` — wordmark previews.
- `Exports/macvoice-favicon-32.png` — 32 px light icon export.
- `Exports/MacVoice.icns` — macOS icon bundle generated from the light icon.

The app build script copies `MacVoice.icns` into the app bundle. SVG files are the editable source of truth. Before a public release, review icon shape, minimum-size legibility, contrast, and platform guidance; the PNG mockups provided with the brief are references, not final production artwork.

## Re-export on macOS

The current PNGs were rendered from SVG with macOS `sips`; `iconutil` assembles the `.icns` from standard iconset sizes. Re-render the PNGs and icon after changing an SVG, then visually inspect the exports. The app bundle is generated under `dist/` and should not be committed as source artwork.
