# 0.3 provisional — delivery polish

- Stable native glass identities transform the action surface into progress and back into save; controls sit outside the inspection viewport.
- Spring-driven queue selection, collapsing queue, drop feedback and cancellable native divider travel. Direct manipulation takes over from presentation geometry.
- Explicit cursor-centered pinch, native momentum, animated fit/100% and high-resolution preview promotion on the first pinch.
- Ordered multi-image drops, latest-selection guards, visible recoverable messages and Reduce Motion window transitions.
- Existing models, precision, alpha, PNG/JPEG exports and adaptive inference are preserved.

# 0.3 provisional — native UX refinement

- Replaced the monolithic queue expression with reusable async thumbnail cells and restrained hover/selection motion.
- Unified the floating controls and the progress HUD in a native Liquid Glass container; their geometry responds together to state changes and to Reduce Motion / Reduce Transparency.
- Retained the native NSScrollView across selection changes, fixed layout re-entry, and added spatial image-settle transitions with immediate trackpad pinch feedback.
- Rebuilt the split comparator on cached Core Animation image layers and an animated mask, so divider movement does not continuously redraw the image pixels. Direct drag tracks the pointer; clicking elsewhere moves the divider quickly and continuously.
- Added a three-color image-derived ambient backdrop, calculated once per preview on a background actor rather than using an expensive per-frame blur.
- Kept the main toolbar limited to the actual task; the optional 75/25 photo fidelity mixture is available from macOS Settings instead of another permanent control.
- Added explicit optional JPEG export, preserving PNG by default and compositing alpha onto white only when the user selects JPEG. Batch export remains PNG.
- Preserved native Core ML, queue, autosizing, offline privacy and the working v0.3 model selection.
- No claim of on-device M5 visual/thermal acceptance or full HDR support.

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
