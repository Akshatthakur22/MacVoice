# MacVoice brand and product guide

**Status:** Foundational guide, v1.0  
**Category:** Local-first voice-typing utility for macOS  
**Primary tagline:** Speak. Type. Done.  
**Campaign line:** Your voice, straight to the cursor.

This guide is the source of truth for product language and brand decisions. It describes intended direction; claims about implemented behavior must still be checked against code and tested results.

## Product definition

MacVoice is a focused voice keyboard for macOS. A user activates a shortcut, speaks, optionally polishes recognized text on-device, and asks the app to type the result into the focused application.

**Mission:** Make speaking to a Mac practical for writing in the apps people already use, without a separate record, transcribe, copy, and paste workflow.

**Product promise:** Speak naturally. Get usable text at your cursor. Stay in your workflow.

MacVoice is not a general-purpose chat assistant, meeting recorder, transcript archive, computer-control agent, or cloud-first writing service.

## Product principles

1. **The cursor is the destination.** The useful outcome is text in the intended field.
2. **Fast by default.** Verbatim mode bypasses the optional polishing worker.
3. **Local-first, described precisely.** Explain what runs locally, what downloads, what is stored, and what permissions are used.
4. **User words remain user words.** Polishing is optional and conservative; preserve the original recognized text when safe if polishing fails.
5. **Respect the clipboard.** The normal insertion implementation uses keyboard events, not clipboard paste. Do not promise a clipboard guarantee until verified across the app.
6. **Insertion compatibility is limited by the destination.** Do not claim that every field or secure surface accepts synthetic keyboard events.
7. **Keep one primary workflow.** Avoid accounts, transcript libraries, dashboards, and unrelated assistant features without evidence they are needed.
8. **Make states clear.** Users should understand idle, listening, processing, typing, and blocked states.
9. **Fail safely.** Do not silently discard recognized words when polishing fails.
10. **Treat trust as interface design.** Explain permissions, cancellation, and data handling plainly.

## Audience and use cases

- People writing messages, email, notes, documents, and browser forms.
- Developers dictating comments, issue descriptions, documentation, identifiers, and commands; technical dictation must be tested before it is promised.
- Mac users who prefer local processing and want clear privacy and clipboard behavior.
- People who want to move thoughts into text with less repetitive typing.

Prioritize browser fields, email and messaging, notes, and documents. Test code editors, terminals, and remote desktops separately before describing support.

## Messaging

**One-sentence description:** MacVoice is a local-first macOS voice keyboard that turns speech into text in the active application, with optional on-device AI polishing.

**Short description:** Speak naturally. MacVoice turns your words into text at the cursor, with a fast Verbatim mode and optional Polished mode.

Preferred phrases:

- “Your voice, straight to the cursor.”
- “Speak. Type. Done.”
- “A voice keyboard for Mac.”
- “Choose Verbatim or Polished.”
- “Designed to avoid clipboard-based insertion in the normal typing path.”

Avoid unsupported claims: “works everywhere,” “zero latency,” “perfect transcription,” “the fastest,” “100% private,” “bypasses blocked paste,” or “types in every secure field.” Use “designed to” for intended but unverified behavior.

## Visual identity

The symbol combines a microphone capsule, a restrained waveform, and a simple stand. Keep the silhouette clear without relying on tiny details. The icon contains no wordmark or tagline. Current SVG and exported files live in [`Brand/`](Brand/README.md).

The supplied concept sheets are visual direction, not production artwork. This repository contains a clean vector interpretation; check actual-size legibility, light/dark contrast, distinctive silhouette, and macOS icon requirements before release.

Use a native system font in the app. Keep surfaces, depth, and motion restrained. Recording feedback must be immediate and must not rely on color alone. Do not imitate Apple's logo, Siri, system dialogs, or another voice product.

## Truth and release discipline

The current project is an early prototype. Apple SpeechAnalyzer is the configured recognizer on macOS 26+, the polisher is opt-in, and TypingCore posts Quartz keyboard events. Destination insertion is not acknowledged by Core Graphics. Report measured results with named hardware and methodology; do not turn a single app smoke test into broad compatibility claims.

Before publishing privacy or performance claims, verify code and behavior, including audio handling, transcript retention, downloads, network activity, permissions, clipboard contents, and destination insertion. See [README.md](README.md), [ARCHITECTURE.md](ARCHITECTURE.md), [COMPATIBILITY.md](COMPATIBILITY.md), [MODEL.md](MODEL.md), and [PERFORMANCE.md](PERFORMANCE.md).
