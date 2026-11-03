# Architecture — 0.3 provisional

## Boundaries

AppModel owns main-actor UI/queue state. PreviewLoader serializes off-main thumbnail/full-view decoding, cancellation and generation checks prevent stale previews. UpscaleEngine is an actor with an explicit busy guard (actor reentrancy alone is not a job lock). Core ML inference, decoding and encoding are off MainActor. Exports run at utility priority using mapped reads and atomic writes. AppKit provides file panels, termination confirmation and window material; SwiftUI provides controls, animations and Liquid Glass.

No external Swift dependencies. No runtime downloads, Python or model conversion. Only the selected model is loaded, and it is released after the job. Results remain in the queue until saved/discarded. File paths are private in diagnostic errors.

## Memory and adaptation

ImageInspector checks dimensions/bit depth before full decoding. JobPlan enforces scale/dimension/output-pixel limits and a physical-memory estimate. A live free+inactive-page estimate adds a conservative preflight check; it is approximate, not a promise of allocatable memory. Dispatch pressure events are the authoritative pressure signal. Critical pressure cancels; memory warnings and thermal fair/serious states shrink subsequent rows.

ResourceGovernor starts with core64, grows to128/192 after six stable rows, and compares seconds per input pixel. A >50% regression backs off with a cooldown. Tile changes happen at row boundaries, preserving complete nonoverlapping coverage. There is one prediction at a time, no speculative parallel allocations. Under normal conditions the engine only yields; it does not sleep. At constrained core64, a 30ms distress delay reduces duty cycle; thermal-critical pauses check cancellation every500ms. This is feedback-driven block sizing plus emergency pacing, not a utilization controller.

Available memory alone does not establish CPU/GPU contention. The governor is a conservative heuristic, not a validated 70–80% hardware budget. M5 headroom and energy efficiency must be measured alongside real browsing before tuning thresholds.

## Images

Core ML uses fixed96/160/224 RGB profiles to avoid the enumerated-shape runtime crash observed in CI. Only the active profile is loaded; byte-identical compiled weight files share bundle storage. Each has16px context around a64/128/192 core. Borders clamp. RGB is unpremultiplied before inference; alpha is independently resampled and restored with Core Image. The sRGB working/output space makes the SDR contract explicit. Resizing occurs before cropping context to reduce independent-resampling seams. At 2× photography selects the native x2plus checkpoint if bundled; illustration 2× downsamples 4× output. 8×/16× are neural inference plus Lanczos, not extra inferred detail. A separate RealPLKSR/NomosWebPhoto option uses a fixed 512×512 image-input Core ML profile, returns a 2048×2048 image buffer and processes 256/384-pixel core blocks with 128/64-pixel context. If optional model installation fails at build time, the mode is hidden and the baseline still works. Intermediate Real-ESRGAN tensor output remains Float16 through Core Image resampling and quantizes to 8 bits only at final PNG rendering. Output limits apply to final dimensions.

Greater-than8-bit sources are rejected. HEIC gain-map enhancement is not processed; SDR base input may be accepted. HDR/wide-gamut preservation and metadata round-tripping are not claimed. Every output embeds an sRGB image color space. The alpha edge test catches accidental white flattening; visual halo/seam assessment on complex artwork remains necessary.

## Design

SF system font; monospaced numbers; warm near-white and graphite neutrals, quiet blue accent. A subdued native behind-window material; neutral solid image surface. Liquid Glass uses Apple's glassProminent button style on macOS26+, with bordered fallback. Reduce Transparency bypasses glass/material decoration where provided; Reduce Motion removes geometry animations. The window adapts to image aspect until the user starts a manual live resize; full-screen or zoomed windows are left alone. Native NSScrollView owns trackpad pinch and inertial two-finger pan, while one AppKit image document draws both versions in aligned pixel coordinates. The divider responds directly to drag and animates quickly only on click. The image transitions with a finite Core Animation fade; there is no persistent idle timer. Animations are interruptible SwiftUI transitions. Pixel100 view uses screen backing scale; fit view never deforms the image.

## Distribution

ZIP remains the deliverable. 0.3 is a prerelease. Homebrew, Developer ID/notarization and full release hardening are1.0 tasks. iPhone and Windows/Rust are separate future ports, not included in0.2.

## Third photographic model and verification

The optional compiled RealPLKSR archive is pinned by SHA-256 and unpacked to build/models/WebPhoto4x.mlmodelc before packaging. It requires no build tool or download in the app runtime. The archived model is from a third-party Core ML conversion; unlike the Real-ESRGAN models, no independent upstream PyTorch parity test is claimed in this repository. The native integration test loads the compiled model, checks output dimensions and preserved alpha. No subjective comparative-photo superiority is asserted without identical input-image evaluation.
