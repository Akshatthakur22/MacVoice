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

Pure text-to-action checks live under `Tests/TypingCoreTests`. They verify scalar
preservation for the written vectors and control-policy mapping, not target app
behavior. See [COMPATIBILITY.md](COMPATIBILITY.md) for observed app test status.
