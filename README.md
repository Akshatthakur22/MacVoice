<p align="center">
  <img src="Brand/Exports/macvoice-logo-light.png" alt="MacVoice — Speak. Type. Done." width="720">
</p>

# MacVoice

**Your voice, straight to the cursor.**

MacVoice is a local-first voice-typing utility for macOS. Focus a text field, start dictation with a shortcut, speak, and MacVoice attempts to type the recognized words into the app you are already using. Choose **Verbatim** for the direct path or **Polished** for optional local text cleanup.

> **Project status:** Prototype in active development. Text insertion and transcription quality still need broader testing; recent manual use has exposed rough and sometimes garbled output. Do not treat one successful session as a reliability or compatibility guarantee.

## How it works

1. Focus the destination text field.
2. Press **Control + Option + Space** or click **Start / Stop Dictation**.
3. MacVoice captures audio in memory and uses Apple's Speech framework to recognize speech for the current system locale.
4. The app ignores provisional speech hypotheses and passes confirmed text onward.
5. **Verbatim** sends that text directly to TypingCore. **Polished** buffers phrases and runs them through an optional local language model.
6. TypingCore posts Quartz keyboard events to the currently focused app. It does not use the clipboard as its normal insertion path.

The app needs microphone permission to listen and Accessibility permission to post keyboard events. Keyboard-event posting is application-dependent: macOS does not confirm that the destination accepted or inserted every character.

After launch, MacVoice stays in the background as a menu-bar utility. Its top-right status shows **Ready**, **Starting**, **Listening**, **Finishing**, or **Attention**; open the menu-bar item to read the full status message, start or stop dictation, open settings, or quit. Closing the control window leaves the menu-bar app and global shortcut active. Launch-at-login is not currently configured.

## Modes

| Mode | What happens | Trade-off |
| --- | --- | --- |
| **Verbatim** | Confirmed speech text goes directly to the typing engine. | Lowest processing overhead; wording and punctuation depend on speech recognition. |
| **Polished (local AI)** | Confirmed text is buffered by punctuation and stop, then sent to a local MLX-LM worker. | Adds phrase-level delay. Current validation allows punctuation/case changes and a few filler removals; it rejects broader word rewrites. |

Polishing is optional. If the model is unavailable or its output fails validation, the original recognized phrase is used where possible. Polished mode does not correct audio recognition itself.

## Requirements and setup

- macOS 26 or later for the current Apple SpeechAnalyzer provider.
- The current distributed build is arm64, so it runs on Apple Silicon Macs; Intel support would require a separate x86_64/universal build.
- Xcode Command Line Tools / Swift Package Manager to build from source.
- Microphone access to capture speech.
- Accessibility access for keyboard-event typing.
- Speech assets for the selected system locale. Install them with **Install Speech Model** while online; the app does not download them automatically when dictation starts.

### Disk space

- The current locally built `MacVoice.app` is approximately **1.2 MB**. Bundle size can vary with the compiler, architecture, and included assets.
- Verbatim mode does not require a separate application-side model download. macOS manages the speech assets independently, and their size depends on the selected locale.
- Polished mode currently needs approximately **680 MB** for the Python/MLX environment plus the Qwen2.5-0.5B-Instruct 4-bit model under `~/Library/Application Support/Typer/MLX/`. Installing both available models takes about **970 MB** on this development Mac. Package caches and future model revisions can change these figures.
- Building from source can use additional temporary SwiftPM data. The current `.build/` directory is approximately **585 MB** and is not part of the installed app.

Build and install the app in your user Applications folder:

```sh
./scripts/build_voice_typing_app.sh
mkdir -p "$HOME/Applications"
ditto dist/MacVoice.app "$HOME/Applications/MacVoice.app"
open "$HOME/Applications/MacVoice.app"
```

Local builds use the stable `MacVoice Local Development` signing certificate in your login Keychain. Keeping that certificate for rebuilds gives macOS a stable Accessibility identity; after switching from an older ad-hoc build, enable **MacVoice** once in **System Settings → Privacy & Security → Accessibility**, then quit and reopen the app. The certificate is only for local development and must not be used to distribute MacVoice. On a machine without it, the build script stops instead of silently creating a new ad-hoc identity; set `MACVOICE_ALLOW_ADHOC_SIGNING=1` only for a temporary build, knowing macOS may require reauthorizing Accessibility after each rebuild.

### Optional local polishing setup

Polished mode requires Apple Silicon, Python 3.10–3.13, and an internet connection for the explicit one-time setup. Choose **Polished**, then **Download Cleanup Model** in the app to install MLX-LM and the selected model. The current primary choice is Qwen2.5-0.5B-Instruct 4-bit. Model and Python files are stored under `~/Library/Application Support/Typer/MLX/` to preserve existing installations.

Normal local inference uses those files on the Mac; the app does not send the audio or transcript to a cloud inference service. Speech assets are installed and managed separately by macOS. See [the model guide](doc/MODEL.md) for model choices and [the performance guide](doc/PERFORMANCE.md) for benchmark results and limits.

## Privacy and data handling

- Audio frames are held in process memory during an active session; the app does not save recordings.
- The app does not maintain a transcript history or app database.
- Speech assets are managed by macOS. Their installation may download data from Apple.
- Optional model setup downloads packages and model files. Ordinary polishing uses the locally installed worker and model.
- Accessibility permission is used for keyboard-event insertion into the focused app.
- No product analytics or transcript telemetry is implemented.

These statements describe this repository's current design and should be rechecked before a public release.

## Compatibility and known limits

- The receiving app and field determine whether posted Unicode and newline events are accepted. Secure fields, custom editors, IMEs, remote desktops, and chat composers may behave differently.
- The app uses the current system locale and reports unsupported locales. Hindi, Hinglish, and other languages are not verified by this project.
- Speech recognition quality, punctuation, and technical vocabulary have not been evaluated across a representative test corpus.
- Global shortcut input monitoring and keyboard-event posting are distinct macOS permissions; the current UI primarily explains Accessibility typing access.
- The current user-facing experience has had manual reports of repeated or garbled text. The cause and cross-app behavior remain under investigation.

See [the compatibility guide](doc/COMPATIBILITY.md) for tested and untested destinations. A successful insertion in one app does not establish compatibility everywhere.

## Development

```sh
swift build
swift run TypingCoreDemo basic
swift run VoiceTypingCoreChecks
```

The reusable `TypingCore` library handles text encoding and Quartz keyboard events. `VoiceTypingCore` connects audio capture, speech recognition, transcript reconciliation, and the optional polishing coordinator. `VoiceTypingApp` is the AppKit host. See [the architecture guide](doc/ARCHITECTURE.md) for the component flow.

Brand principles and vector artwork live in [the brand guide](doc/BRAND.md), [the design system](doc/DESIGN_SYSTEM.md), and [`Brand/`](Brand/README.md).

## Project structure

- `Sources/TypingCore/` — append-only keyboard-event typing engine.
- `Sources/VoiceTypingCore/Audio/` — in-memory microphone capture.
- `Sources/VoiceTypingCore/Speech/` — speech-recognizer contract and Apple SpeechAnalyzer adapter.
- `Sources/VoiceTypingCore/Transcript/` — confirmed transcript reconciliation.
- `Sources/VoiceTypingCore/Polishing/` — phrase buffering, local model bridge, and output validation.
- `Sources/VoiceTypingCore/Integration/` — session lifecycle and component coordination.
- `Sources/VoiceTypingApp/` — native macOS control window and menu-bar app.
- `Resources/` and `scripts/` — app metadata, local model worker, setup, build, and benchmark tools.
- `Brand/` — editable SVG source and exported MacVoice identity assets.
- `Tests/` — deterministic library-level tests; these do not verify microphone capture or destination-app insertion.

## Brand and claims

MacVoice's primary tagline is **Speak. Type. Done.** The product is intended to be a focused voice keyboard, not a general AI assistant. The brand guide distinguishes product intent from implemented and verified behavior. Avoid claims such as “works everywhere,” “zero latency,” “perfect accuracy,” or “100% private.”

## License

No repository license file is present yet. Do not assume the project or its artwork is licensed for redistribution until a license is added.
