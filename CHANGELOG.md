# 0.3 provisional

- Optional RealPLKSR/NomosWebPhoto Core ML photographic alternative with pinned compiled-model archive and native pixel-buffer inference tests.
- Native NSScrollView comparison canvas for trackpad pan/pinch zoom, instant divider drag, rapid click transitions and shared original/result framing.
- Intermediate Float16 Core Image output eliminates early 8-bit rounding before final down/up-resampling.
- Keyboard shortcuts and stale-preview comparison guards; existing batch/save/cancel behavior retained.

- Model catalog with immutable checkpoint and Core ML input/output contracts.
- RealESRGAN_x2plus available as native photo 2× inference, with x4 fallback.
- Avoids Lanczos when the network already outputs the requested scale.
- Immersive image-led workspace, draggable and clickable split comparison, horizontal deferred-thumbnail queue, floating controls and macOS Liquid Glass container.
- Adaptive window geometry stops after the user manually resizes.
- Throttles UI progress publication while preserving engine progress and cancellation.
- CI parity and end-to-end validation now include the optional Photo2x model.
- SDR sRGB/8-bit, alpha and output size limits remain as in 0.2.
- Real-world M5 visual, thermal and gesture acceptance is outstanding; new-model fidelity claims require paired image assessment.

# Changelog

## 0.2.0 — Adaptive native preview (prerelease)

- Added photography model alongside illustration/anime; pinned weights and per-shape conversion validation.
- Replaced the manual slow toggle with memory/thermal/throughput-based tile sizing and distress-only pacing.
- Preserved alpha, standardized explicit SDR sRGB output, and added 8×/16× sizing with an honest 4×-model explanation.
- Added sequential queues, retry, batch export, unsaved-result protection and background saving/loading.
- Redesigned light/dark appearance with neutral colors, system typography, compact controls, native materials and Liquid Glass fallback.
- Added double-click import, adaptive aspect-ratio transitions, original/result toggle, 100% view and accessibility handling.
- Added policy and real-model integration tests, model provenance and release packaging.

Known acceptance work: real M5 multitasking/thermal benchmarks; complex alpha-edge and seam visual review; keyboard/VoiceOver and animation assessment on user hardware. HDR output, Homebrew, production signing and ports remain explicitly outside this prerelease.

## 0.1.0

Initial native anime-model prototype, fixed blocks, manual gentle mode, single images, 2×/4×, white-backed alpha, GitHub macOS CI.
