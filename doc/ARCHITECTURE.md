# VoiceTyping architecture

## Modules

- `TypingCore` remains the existing independent append-only Quartz event library.
- `VoiceTypingCore.AudioCapture` captures microphone buffers with `AVAudioEngine`, copies them to in-memory PCM frames, and exposes host-driven microphone permission.
- `SpeechRecognizer` is the replaceable backend contract. The current provider, `AppleSpeechAnalyzerRecognizer`, uses the macOS Speech framework on macOS 26 and later.
- `TranscriptReconciler` ignores provisional hypotheses, accepts only cumulative confirmed text, rejects revisions to confirmed UTF-8 bytes, and withholds the last grapheme until a later update/finalization.
- `VoiceTypingSession` owns the Idle → Starting → Listening → Stopping → Idle / Failed lifecycle and connects the components.
- `GlobalShortcut` registers a configurable Carbon hotkey (Control+Option+Space by default). The AppKit host stores the key code, Carbon modifier mask, and display label together in one `UserDefaults` dictionary; failed registrations restore the previous binding.

```text
Menu-bar host / hotkey
       │
       ▼
VoiceTypingSession state machine
       ├───────────────┐
       ▼               ▼
 AVAudioEngine     SpeechRecognizer
       │             (Apple SpeechAnalyzer now;
       │              replaceable contract)
       ▼               │
 copied PCM frames ────┘
                       │ volatile + finalized results
                       ▼
               TranscriptReconciler
                       │ confirmed deltas
                       ▼
                Mode coordinator
                  ┌─────┴─────┐
              Verbatim     Polished
                  │       phrase buffer
                  │            │ local MLX worker
                  └─────┬──────┘
                        ▼
                TypingCore.append
                       │ Quartz keyboard events
                       ▼
             currently focused macOS app
```

The audio frame stream has a 32-frame cap. If recognition falls behind capture
and a frame is dropped, the session fails and stops rather than silently
continuing with missing audio. Transcript updates are cumulative snapshots; the
reconciler ignores provisional hypotheses and rejects changes to confirmed text.

The audio tap callback copies hardware Float32 samples into an interleaved
`[Float]` value, then yields it to the bounded stream. Resampling and format
conversion happen on the recognizer consumer task, outside the audio callback.
Audio exists only in process memory while the session is active. No recordings or recognized transcript history are written to disk. UI preferences (typing mode, appearance, and global shortcut) are stored in `UserDefaults`.

Installing speech assets is the exception to the app-local storage boundary:
the app asks macOS to install and manage those assets. They are not bundled in
`VoiceTyping.app`; macOS may reclaim them, and the app checks their status on
the next start.

## Apple Speech asset lifecycle

`AppleSpeechAnalyzerRecognizer.start()` only proceeds when macOS reports the
locale's speech assets as installed. `installAssets()` is a separate explicit
operation from the menu and may download Apple-managed model assets. Once
installed, recognition is on-device. macOS manages and may reclaim those assets;
the app checks availability again on each start. If assets are absent, the app
does not silently use a network recognizer or start a download.

## Optional local transcript polishing

In Verbatim mode, stable deltas are appended directly and the polishing worker is
not started. In Polished mode, confirmed text is buffered through punctuation
boundaries, processed serially by the selected local MLX-LM model, validated, and
then appended. Stop flushes the phrase tail. Apple SpeechAnalyzer does not currently
provide pause timing to this path, so silence-based phrase detection is not present.
The Python worker loads its model once per process. Installation is explicit;
ordinary inference uses local files only. `TypingCore` remains independent of
speech and model code.

Apple SpeechAnalyzer marks result ranges as volatile or final. Only final
result text contributes to the reconciler's confirmed prefix. The current app
uses the host's current locale and reports unsupported locales rather than
guessing. There is no model fallback yet.

## Boundaries and current gaps

- The voice library knows text origin but not key-event implementation details; TypingCore knows nothing about audio or speech.
- TypingCore completion still means Quartz events were posted, not inserted into the destination.
- The app requires macOS 26 for its current provider. The reusable voice library is declared for macOS 14, but `AppleSpeechAnalyzerRecognizer` is availability-gated to macOS 26.
- One English dictation was manually verified by the user in TextEdit on macOS 26.6.2 / Apple Silicon, including microphone capture, installed speech assets, the global shortcut, and destination typing. This is a single manual smoke test, not broad compatibility coverage.
- English has one basic successful smoke test; no other language or accuracy level is verified.
