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
XCTest suite also contains those checks and a deterministic mock recognizer, but
`swift test` could not run in this environment because the selected Command Line
Tools installation does not include the XCTest module.

## Optional MLX transcript polisher

`scripts/benchmark_local_polisher.py` replays `Resources/polisher_benchmark.json`
against the installed Qwen model. It reports model-load-to-ready time and warm median/p95
per-phrase latency, median time to first generated text, child process CPU time,
peak RSS, mean whitespace-token WER, mean Unicode-character error rate, plus every
output for human review against the reference.
Example: `python3 scripts/benchmark_local_polisher.py --repeats 3`.
It does not measure actual destination typing latency.

### Local run, 2026-10-09

Hardware: MacBook Air (Mac16,12), Apple M4, 16 GB unified memory, arm64; macOS
version from `sw_vers` was 26.6.2. The pinned Qwen revision listed in `MODEL.md` was
installed locally and ran the same 12 transcript examples three times each, with
greedy decoding and one persistent worker. Cold startup is process plus
model loading; warm latency includes phrase prefill and all generated output.

| Model | Cold worker startup | Warm phrase median / p95 | First generated text median | Worker CPU | Peak RSS | Mean WER / CER |
|---|---:|---:|---:|---:|---:|---:|
| Qwen2.5 0.5B 4-bit | 1.295 s | 0.159 / 0.201 s | 0.118 s | 4.311 s | 536.8 MiB | 14.8% / 8.1% |

These 12 short examples are a smoke benchmark, not a broad accuracy evaluation;
WER/CER do not detect every meaning change. The app's conservative validator
rejects word changes beyond known filler removals and falls back to the original
phrase when output appears unsafe.

`swift run VoiceTypingCoreChecks --mlx` also exercised the Swift JSON-lines bridge
against Qwen on this Mac. It returned “I think we should ship it next week.” in
2.273 s including the first worker/model launch on the latest run. Microphone capture and insertion
into a real destination app were not part of this run.
