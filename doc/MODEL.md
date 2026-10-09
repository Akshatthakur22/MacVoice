# Speech model evaluation

## Current implementation

The initial adapter is Apple's `SpeechAnalyzer` / `SpeechTranscriber`, gated to
macOS 26 or later. This is a pragmatic native baseline: no third-party runtime
is added, Apple documents on-device processing, and results expose explicit
finalization information. Asset installation is explicit and may require an
online download. Model architecture, disk footprint, CPU, app memory, startup,
latency, and accuracy on this Mac are not exposed or measured here. Locale
availability is queried at runtime. This is not yet an evidence-based final
winner.

## Candidate comparison

| Candidate | Model / architecture and size | Streaming | CPU, RAM, startup, latency | Accuracy, punctuation, language | macOS / Swift integration and license |
|---|---|---|---|---|---|
| **Apple SpeechAnalyzer (current baseline)** | Proprietary system-managed SpeechTranscriber model; app bundle size is zero for model assets | Native progressive/volatile results and explicit finalization | Not measured or reported by the app; Apple says the model runs outside app memory | Locale list is device/runtime dependent; punctuation quality and Hindi/Hinglish performance not measured | Native Speech framework; macOS 26+ in this app; assets explicitly installed via Apple and may be reclaimed by OS; Apple platform terms |
| **Moonshine Small Streaming** | Sliding-window streaming encoder plus autoregressive decoder; 123M parameters | Designed for streaming; encoder processes speech incrementally | Vendor benchmark reports phrase-final latency and compute; no local RAM/startup values | Vendor reports 7.84% English WER averaged across eight Open ASR Leaderboard datasets. Current streaming list has no Hindi. Punctuation not separately scored | Swift package and macOS example; ONNX Runtime `.ort` models; runtime/model assets add integration work; MIT for streaming models |
| **Moonshine Tiny Streaming** | Same streaming family; 34M parameters | Streaming | Vendor benchmark candidate; local resource values unknown | Vendor reports 12.00% English WER; current streaming languages do not include Hindi. Punctuation not separately scored | Same Moonshine integration considerations; ONNX Runtime; MIT |
| **WhisperKit Tiny multilingual** | Whisper encoder-decoder; 39M parameters | Provides live audio APIs with confirmed/unconfirmed segments; decoding is not an incremental streaming encoder | Core ML load/runtime costs need measurement; not measured here | Multilingual Whisper includes Hindi, but Hinglish/code-switch quality is unknown. Punctuation is model-generated and not measured here | Swift package and Core ML; model assets are separate and must be installed/bundled for offline use; Argmax OSS and upstream Whisper are MIT |
| **whisper.cpp Tiny multilingual** | Whisper encoder-decoder; 39M parameters; upstream lists 75 MiB original and 31 MiB Q5_1 GGML weights | Repository includes a real-time microphone example; chunking can revise hypotheses and requires reconciliation | Apple Silicon Accelerate/Metal/Core ML paths exist; no measurements on this host | Multilingual Whisper includes Hindi; real-world Hindi/Hinglish and punctuation accuracy remain to be measured | C/C++ API with Swift bridging/build work; whisper.cpp MIT and upstream Whisper MIT |
| **faster-whisper Tiny/Base** | Whisper encoder-decoder via CTranslate2; weight size depends on model and quantization | Chunked/batch API, not an irrevocable streaming transcript contract | CPU/GPU paths exist; Python runtime is a poor fit for a small native host; local RAM/startup/latency unknown | Multilingual coverage depends on selected Whisper checkpoint; no project-specific accuracy data | Python/CTranslate2 integration, not direct Swift; faster-whisper MIT |

Moonshine's English accuracy and timing values are vendor-published results,
not results from this repository. Its benchmark feeds a fixed `two_cities.wav`
in chunks and reports phrase-final latency; that is useful context but is not a
direct measurement of time-to-visible-text in this app. Apple and WhisperKit
values are not compared numerically because no common local corpus has been run.

## Selection decision

Use Apple SpeechAnalyzer as the first implementation on macOS 26 because it
provides a native on-device path and stable/final result boundaries without
adding a model runtime dependency. Keep `SpeechRecognizer` replaceable. Do not
claim it is fastest or most accurate. Moonshine Small Streaming is the strongest
English latency candidate; WhisperKit/whisper.cpp remain important comparators
for Hindi and multilingual coverage. Benchmark before treating the current
provider as final.

## Required benchmark before a final choice

Use identical licensed English, Hindi, Hinglish/code-switch, and noisy-mic
recordings with reference text. Record cold model/asset preparation separately
from warm start. Measure time to first hypothesis, time to first stable text,
finalization latency, WER/CER, punctuation, process CPU, peak RSS, and energy
over repeated runs on the target Mac. Keep provider and app latency separate;
also measure TypingCore event submission independently from target insertion.

## Optional transcript polisher implementation

The voice app has one optional text cleanup model, separate from speech recognition.
When the user selects Polished mode and chooses its setup action, MacVoice installs
`mlx-community/Qwen2.5-0.5B-Instruct-4bit` (revision
`a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`) through MLX-LM. Verbatim mode does not
start the model worker. The [Qwen MLX artifact](https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit)
publishes an Apache-2.0 license.
An explicit setup action installs pinned `mlx-lm==0.31.3`, `mlx==0.32.3`,
`transformers==5.17.0`, and `huggingface_hub==1.5.0` into a Python 3.10–3.13
virtual environment, then downloads the Qwen checkpoint to the user's Application
Support directory. In this environment the Qwen model occupied about 276 MiB and the
Python environment occupied 408 MiB. A persistent local Python process
loads the model once and accepts newline-delimited JSON requests from Swift over stdin/stdout.
No HTTP server or cloud inference service is used. Local results and their limits
are recorded in `PERFORMANCE.md`.

## Primary references

- [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) and [Apple's on-device SpeechAnalyzer session](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Moonshine available models](https://moonshine-voice.readthedocs.io/en/latest/models/available-models/) and [Moonshine benchmark methodology](https://moonshine-voice.readthedocs.io/en/stable/using/benchmarks/)
- [Moonshine Swift package](https://github.com/moonshine-ai/moonshine-swift)
- [WhisperKit / Argmax OSS](https://github.com/argmaxinc/argmax-oss-swift) and [OpenAI Whisper model card](https://github.com/openai/whisper/blob/main/model-card.md)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and [faster-whisper](https://github.com/SYSTRAN/faster-whisper)
