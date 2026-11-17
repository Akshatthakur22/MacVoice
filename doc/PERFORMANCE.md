# Performance status

## Measured in this repository

No end-to-end microphone-to-destination performance measurements have been
collected. A single English TextEdit dictation was previously reported by the
user. The local transcript-polisher measurements are recorded separately below;
speech recognition and destination insertion latency remain unmeasured here.

The package and app executable compile successfully with the selected macOS
26.6.2 Command Line Tools SDK. Compilation time is not a model performance
measurement.

## Measurement plan

Benchmark the same pre-recorded PCM clips through each provider at real-time
frame intervals. Record provider startup and model/asset setup separately;
first hypothesis and first confirmed-text times; final-result delay after
end-of-speech and stop; audio frame overruns; process CPU and peak RSS; WER/CER
and punctuation on English, Hindi, and Hinglish clips; and TypingCore submission
timing separately from destination text readback.

Run cold and warm sessions, repeat at least three times, and note machine/OS,
locale, input format, microphone, model/asset versions, and destination app.
There is no speech-recognition benchmark runner or destination readback harness yet.
Do not interpret vendor numbers in `MODEL.md` as local measurements.

The `VoiceTypingCoreChecks` executable exercises stable-prefix extraction,
combining-sequence boundaries, and rejection of confirmed-text revisions. The
Swift Testing suite (`swift test`) covers those checks, the session lifecycle with
a deterministic mock recognizer, transcript assembly, and the Polished-mode rules.

## Transcript polisher

Polished mode runs `NativeSwiftTranscriptPolisher` in-process: regular
expressions and word lists only, with no model or worker process. Cleanup cost is
negligible next to recognition and typing; it does not measure destination
typing latency.
