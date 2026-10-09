# TypingCore prototype

A small macOS-only Swift package that progressively posts Unicode-bearing Quartz
keyboard events to the currently focused app. It has no third-party dependencies
and does not use the clipboard. It is intentionally separate from the Typer app.

## Build and manual probe

```sh
cd TypingCore
swift build
swift run TypingCoreDemo basic
swift run TypingCoreDemo unicode
swift run TypingCoreDemo long
swift run TypingCoreDemo newline --newline=newline
```

The demo waits five seconds, then types into the currently focused field. Try the
basic sample in TextEdit and a browser text field, then try Unicode and long text.
The demo reports elapsed time, graphemes/second, process CPU time, and resident
memory before and after the typing run. These are process-level measurements, not
system-wide CPU measurements. Enqueue-to-completion time is reported; true
first-event latency and whether a particular app accepted every character need an
event-tap or target-side probe. This prototype has not been manually validated in
every target app or language input method.

The sample corpus covers ordinary prose, punctuation, digits, ASCII symbols,
accented Latin, Indian currency, typographic punctuation, emoji, Hindi, newline
handling, and a repeated paragraph. Newline handling is configurable with
`--newline=newline|enter|shift-enter|omit`; the demo defaults to `newline`.
`shift-enter` tries the common chat line-break shortcut. Library callers
must select a `NewlineBehavior` when constructing the engine, so the behavior
is never silently guessed. Compare the expected
output in a plain text editor and record the macOS version, target app, and
keyboard/input source. Secure Input fields are expected to reject or suppress
injected events.

Additional demo vectors: `punctuation`, `typography`, `whitespace`, `unicode`,
`combining`, `emoji`, and `speech`. `--delay=0|1|5|10` selects inter-grapheme
pacing in milliseconds. `stream` rapidly queues append chunks, including a
split emoji sequence. `cancel` queues a long run and stops after 50 ms;
`cancel-now` tests stop immediately after enqueue. These
exercise the engine path but still require checking the resulting text in the
target application.

Shift+Return uses an internal 25 ms settling pause on both sides of the line
break. This gives apps time to process adjacent text without slowing every
ordinary character or requiring a per-app delay setting. It remains best-effort:
target applications can still interpret keyboard events differently.

## API

```swift
let engine = TypingEngine(interCharacterDelay: 0.005, newlineBehavior: .newline)
engine.type("Hello, world!") { result in
    // Completion runs on the main queue. Success means events were posted,
    // not that the focused app accepted or rendered them.
}

// Later speech output that is genuinely new:
engine.append(" How are you?")

// Cancels queued work at the next grapheme boundary:
engine.stop()
```

Calls are submitted to a serial utility queue and return immediately. The default
5 ms inter-grapheme delay is a compatibility knob to avoid sending a dense burst;
use zero for minimum latency and test it in the actual target app. Stop does not
undo text already delivered. A caller must serialize transcript corrections and
decide whether to append, revise, or ignore them.

## Scope and limitations

`CGEvent.keyboardSetUnicodeString` supplies UTF-16 text on a Quartz keyboard
event. Apple documents that application frameworks may ignore that Unicode
payload and translate the virtual keycode/event state themselves. Therefore this
is layout-independent in the event payload, but it is not universal text
insertion. The engine uses virtual keycode zero for printable graphemes. Tab is
sent as a Unicode control payload instead of a Tab keycode to avoid
intentionally moving focus. Newlines have four explicit modes: `.newline`
preserves CR and LF scalar payloads, `.enter` maps each CR/LF scalar to Return,
`.shiftEnter` maps each to Shift+Return, and `.omit` skips line breaks. For
`.newline`, a CRLF pair is sent as CR then LF,
even when split across append calls. There is no CGEvent guarantee that Unicode control payloads become text
instead of app commands; a chat field may still treat LF as Send. Tab insertion
also remains app-dependent. IMEs, secure fields, games, remote desktops, and apps with
custom text handling may ignore or transform events. Emoji and scripts such as Hindi
are passed as one Swift grapheme's UTF-16 sequence, but target-app support must be
measured; CGEvent does not perform normal keyboard-layout or IME composition.

The only permission check included is `CGPreflightPostEventAccess()`. The host
application owns any permission request and user-facing explanation. Event posts
are asynchronous from the engine's perspective: Core Graphics offers no receipt
that the target inserted a character. Completion returns a `TypingReport` with
the number of event pairs submitted and time-to-first-post, or an error with the
partial count where relevant. This is not a text-insertion acknowledgement. A low-level event should not be described
as indistinguishable from a physical keyboard; this module's goal is progressive
keyboard-event delivery rather than hardware authenticity.

`Tests/TypingCoreTests` contains transcript reconciliation and PCM value tests,
plus a deterministic fake recognizer. These tests do not exercise microphone or
destination-app behavior. See [COMPATIBILITY.md](COMPATIBILITY.md) for observed
app test status.

## Voice typing prototype

The package also includes a separate `VoiceTypingCore` library and a small
macOS app with a control window and menu-bar status item. The host requires
macOS 26 or later and uses Apple's on-device `SpeechAnalyzer` for the current
system locale. Press **Control+Option+Space** to toggle listening. Choose
**Install Speech Model** while online before using the app offline; starting a
session does not download speech assets.

Build a local app bundle with:

```sh
./scripts/build_voice_typing_app.sh
open dist/VoiceTyping.app
```

Run the deterministic transcript safety checks without a test framework:

```sh
swift run VoiceTypingCoreChecks
```

The host requests microphone access on the first explicit start. The app bundle
declares the microphone usage description. Use **Allow Keyboard Typing Access**
to request macOS Accessibility permission for event posting. Audio buffers stay
in memory; provisional hypotheses are not typed, and only confirmed text reaches
`TypingCore.append`. Speech assets are installed and managed by macOS rather than
stored inside the app bundle. The user has confirmed one English dictation into
TextEdit; other apps and languages still need testing.

This is an early prototype. Apple's model locale support is checked at runtime;
Hindi and Hinglish support are not claimed until verified. See [ARCHITECTURE.md](ARCHITECTURE.md),
[MODEL.md](MODEL.md), and [PERFORMANCE.md](PERFORMANCE.md).

## Optional local transcript polishing

The VoiceTyping window offers **Verbatim** (the default) and **Polished (local AI)** modes.
Verbatim preserves the existing low-latency path and does not start Python or load an LLM.
Polished mode buffers confirmed text until sentence punctuation, then sends one phrase at a time
to a persistent local MLX-LM worker. The remaining phrase is polished when dictation stops.
SpeechAnalyzer currently exposes no pause timing to this integration, so punctuation and stop
are the phrase boundaries; a silence-based boundary is not implemented.

The primary model is `mlx-community/Qwen2.5-0.5B-Instruct-4bit` at revision
`a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`. The comparison choice is
`mlx-community/SmolLM2-360M-Instruct-6bit` at revision
`642affd1f9e387d1b56c745894afc83795aebe1d`; its available MLX artifact is 6-bit,
not 4-bit. Select a model in the window and choose **Install Local Polishing Model**.
Setup requires Apple Silicon, macOS 26+, Python 3.10–3.13, and an internet connection for the
one-time MLX-LM environment and model download. Files go to
`~/Library/Application Support/Typer/MLX/`. Normal inference uses only those local files
and does not send audio or transcript text over the network. The worker loads its selected
model once and stays alive for inference requests. The app does not bundle Python or model
weights; Python and the model are installed separately in that user support directory.

Polished mode never types an unpolished phrase first. Failed/invalid AI responses fall back
to the original phrase. The worker has a 12-second request timeout. Validation allows
punctuation/case changes and removal of `um`, `uh`, or `erm`, but requires all other words
to remain in the same order. This intentionally rejects broader grammar rewrites; it reduces
meaning changes but cannot prove semantic fidelity.
At more than 16 waiting phrases the session stops taking new audio and drains queued phrases
verbatim to avoid dropping confirmed words. `TypingCore` remains unchanged and append-only.
After setup, compare both installed choices with `python3 scripts/benchmark_local_polisher.py`;
it reports cold worker startup, warm median/p95 phrase latency, first-token latency, and all
output/reference pairs, child CPU and peak RSS, and exploratory WER/CER. Run one model per
invocation for clean child RSS measurements. The local benchmark results are recorded in
`PERFORMANCE.md`; reference text metrics are not a substitute for semantic review.

After installation, verify the Swift-to-worker bridge with
`swift run VoiceTypingCoreChecks --mlx`. It performs one real local phrase cleanup and then
shuts down the persistent worker.
