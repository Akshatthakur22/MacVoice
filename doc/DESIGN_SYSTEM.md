# MacVoice design system

**Status:** Brand reference and UI direction. Native controls use system colors so they adapt to macOS appearance.

## Color tokens

| Token | Value | Intended use |
| --- | --- | --- |
| Primary Blue | `#0A84FF` | Primary action and brand accent |
| Light Blue | `#64D2FF` | Secondary accent and waveform highlights |
| Graphite | `#1D1D1F` | Main text on light surfaces |
| Deep Navy | `#0B1220` | Dark brand surfaces |
| Surface Light | `#F5F7FA` | Light brand surfaces |
| Surface Dark | `#151922` | Dark brand surfaces |
| Secondary Text | `#667085` | Supporting copy; verify contrast per size |
| Success / Warning / Error | Semantic system colors | State feedback, never decoration |

Prefer semantic macOS colors for native controls. Brand colors are not a replacement for system state colors. Check contrast in both appearances.

## Typography

- Use the macOS system font in the native UI.
- Use a clean sans-serif wordmark treatment; do not require an unlicensed font to render the editable SVG.
- Use size and weight for hierarchy; keep functional text tracking normal.
- Use monospaced type for shortcuts and technical identifiers where it helps.

## Shape and depth

- Use restrained rounded corners and consistent alignment.
- Add depth only when it clarifies hierarchy.
- Avoid decorative glow, heavy bevels, constant gradients, and glass effects that reduce contrast.
- Let macOS provide familiar controls and surfaces where practical.

## Icon and logo use

- The app icon is symbol-only; do not put “MacVoice” or the tagline inside it.
- Keep light and dark icon variants for contexts that need each appearance.
- Use the horizontal wordmark on documentation and marketing surfaces, not in compact menu-bar controls.
- The symbol should remain identifiable at 16, 32, 64, and 128 px. Verify this with rendered previews before release.
- Keep clear space around the mark; do not stretch, skew, or recolor it outside documented variants.
- Do not add Apple logos, system badges, or claims of Apple endorsement.

## Motion and recording state

- Motion confirms a state change; it does not decorate inactivity.
- Show listening state immediately and clearly.
- Respect reduced motion and avoid unnecessary sound effects.
- Never rely on color or animation alone to communicate active recording.

## Native app implementation

- Use AppKit controls and the user's system appearance; reserve brand blue for the microphone mark and primary emphasis.
- Use native Dictate, Modes, Shortcut, Settings, and About tabs. Keep Start/Stop and current state in Dictate; expose shortcut recording in its own section and retain the Control+Option+Space default. Show cleanup-model setup only in Polished mode. Appearance can follow System or be set to Light or Dark.
- Use explicit status text as well as a semantic color: Ready, Starting, Listening, Finishing, or an actionable failure.
- Make the primary action reachable with Return, keep mode controls unavailable while a dictation is active, and show a keyboard-accessible shortcut recorder with a conflict-safe reset path.
- Do not show polishing, typing, or success progress unless the session exposes those states. The current session reports starting, listening, stopping, and failure only.
- Validate VoiceOver labels, keyboard focus order, reduced motion, and contrast in both appearances during manual release review.

## Current exports

See [`Brand/README.md`](Brand/README.md) for the SVG masters, PNG previews, and `MacVoice.icns` app icon bundle. These are the first clean vector pass based on the supplied concept image, not final usability or distinctiveness approval.
