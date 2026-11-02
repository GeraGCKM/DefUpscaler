# Requirements and acceptance — 0.2

| Order | Requirement | Implementation / verification |
|---|---|---|
|1|Native, minimal dependencies and debugging|SwiftUI/AppKit/Core ML; separated services; tests, private diagnostics and pinned sources|
|2–3|Adaptive load and usable headroom|Live memory preflight, pressure/thermal events, measured per-pixel timing, row-boundary tile changes; no exact utilization claim; M5 benchmark pending|
|4|Two models|Anime6B and general x4plus; conversion parity for every supported patch size|
|5|Image transparency|Separate alpha restoration; automated transparent/semitransparent samples; complex halo review pending|
|6|Color/HDR|Explicit SDR8 sRGB conversion; reject deep input; HEIC base SDR only; no HDR output claim|
|7|2×/4×/8×/16×|Final dimension/memory guards;4× model plus resampling clearly labelled|
|8|Batches|Sequential queue, isolated item errors, unique batch filenames, retry|
|9|Input|Drop, double-click, picker, keyboard; multiple files supported|
|10|Minimal controls|Mode, scale, primary action; secondary menu; no duplicate app heading or local badge|
|11|Aspect ratio|Fit surface follows image; fixed user-controlled window; no distortion|
|12–14|Antinote-inspired neutral design|System typography, monospaced measurements, graphite/warm light, quiet blue; system/manual appearance|
|15|Native glass|Apple glassProminent on macOS26+, older fallback; native material; neutral preview|
|16|Stability|Policy, dimension, orientation, alpha and scale tests; conversion parity, packaging/signature check; manual Mac QA pending|
|17|Animations last|Interruptible geometry transition after preview decode; old preview retained; Reduce Motion; manual fluidity check pending|
|18|ZIP|Retained|
|19|1.0 distribution|Homebrew, Developer ID and notarization deferred as agreed|
|20|Ports|iPhone and Windows/Rust deferred as agreed|

Additional details: last selection wins; serial preview decoding; fit/100% modes; original/result toggle; loading/upscaling/encoding/saving phases; unsaved-result confirmation on reset/quit; original file overwrite blocked; failed export preserves temporary results; batch collisions get numeric suffixes. Images added during processing join the current queue with that run's captured mode/scale.

The 100% view shows each selected image's actual pixels rather than aligning a source pixel to its scaled result. Fit view keeps equivalent framing for comparison. There is no automatic whole-window resize, deliberately avoiding disruptive movement. These decisions favor a predictable lightweight utility.
