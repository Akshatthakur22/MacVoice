# Performance status

## Measured in this repository

No VoiceTyping runtime performance measurements have been collected. A single
English TextEdit dictation was manually confirmed by the user, but there are no
local CPU, RSS, energy, first-hypothesis, first-stable-text, finalization, WER,
or CER measurements yet.

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
There is no automated benchmark runner or destination readback harness yet.
Do not interpret vendor numbers in `MODEL.md` as local measurements.

The `VoiceTypingCoreChecks` executable exercises stable-prefix extraction,
combining-sequence boundaries, and rejection of confirmed-text revisions. The
XCTest suite also contains those checks and a deterministic mock recognizer, but
`swift test` could not run in this environment because the selected Command Line
Tools installation does not include the XCTest module.
