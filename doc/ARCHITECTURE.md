# VoiceTyping architecture

## Modules

- `TypingCore` remains the existing independent append-only Quartz event library.
- `VoiceTypingCore.AudioCapture` captures microphone buffers with `AVAudioEngine`, copies them to in-memory PCM frames, and exposes host-driven microphone permission.
- `SpeechRecognizer` is the replaceable backend contract. The current provider, `AppleSpeechAnalyzerRecognizer`, uses the macOS Speech framework (`SpeechAnalyzer` and `SpeechTranscriber`).
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
                  │            │ Native Swift Polisher
                  └─────┬──────┘
                        ▼
                TypingCore.append
                       │ Quartz keyboard events
                       ▼
             currently focused macOS app
```

The audio frame stream has a bounded cap. If recognition falls behind capture
and a frame is dropped, the session fails and stops rather than silently
continuing with missing audio. Transcript updates are cumulative snapshots; the
reconciler ignores provisional hypotheses and rejects changes to confirmed text.

The audio tap callback copies hardware Float32 samples into an interleaved
PCM frame, then yields it to the bounded stream. Resampling and format
conversion happen on the recognizer consumer task, outside the audio callback.
Audio exists only in process memory while the session is active. No recordings or recognized transcript history are written to disk. UI preferences (typing mode, appearance, and global shortcut) are stored in `UserDefaults`.

Installing speech assets is the exception to the app-local storage boundary:
the app asks macOS to install and manage those assets. They are not bundled in
`VoiceTyping.app`; macOS may reclaim them, and the app checks their status on
the next start.

## Apple Speech asset lifecycle

`AppleSpeechAnalyzerRecognizer.start()` only proceeds when macOS reports the
locale's speech assets as installed. Before each dictation, the host checks
`SpeechTranscriber.supportedLocales` and `installedLocales`, chooses a locale
matching the system language (preferring an installed regional model), and
automatically calls `installAssets()` when needed. This may download
Apple-managed model assets. It checks
the asset inventory after the download request and only reports success when
the assets are installed; pending and unsupported states are surfaced to the
host. Once installed, recognition is on-device. macOS manages and may reclaim
those assets; the app checks availability again on each start. If assets are
absent, the app does not silently use a network recognizer or start a download.
When a user presses **Try Again** after a failed dictation, that explicit action
checks the asset inventory and restores missing speech assets before retrying.

## Native transcript polishing

In Verbatim mode, stable deltas are appended directly and the polisher is
bypassed. In Polished mode, confirmed text is buffered through punctuation
boundaries, processed in-process by `NativeSwiftTranscriptPolisher`, and
then appended. Stop flushes the phrase tail.

`NativeSwiftTranscriptPolisher` is a stateless, pure-Swift polishing engine
executing in under 0.1 ms with zero external Python dependencies or disk overhead.
It performs:
1. Voice navigation commands (`new line`, `shift enter`, `bullet point`, `new paragraph`).
2. Smart filler removal (`um`, `uh`, `erm`, `ah`) with legitimate repeat preservation (`that that`, `had had`).
3. Common contraction normalization (`dont` → `don't`, `im` → `I'm`).
4. Sentence capitalization across lines, paragraphs, list bullets, and sentence boundaries.
5. Multilingual safety: English-specific normalization is scoped to English locales.

## Boundaries and current gaps

- The voice library knows text origin but not key-event implementation details; TypingCore knows nothing about audio or speech.
- TypingCore completion means Quartz events were posted, not inserted into the destination.
- AppleSpeechAnalyzerRecognizer requires macOS on-device speech transcription features.
