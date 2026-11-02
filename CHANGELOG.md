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
