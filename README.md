# DefUpscaler 0.3 — provisional build

> **Provisional 0.3 build.** GitHub Actions passed native Core ML numerical parity and packaged inference on macOS; real Mac M5 thermal, multitasking, alpha-edge and UI acceptance remain outstanding. This is not a signed/notarized production release. See [the temporary validation report](docs/PROVISIONAL_COREML_VALIDATION.md).

A small native macOS app for **drop → choose mode and scale → upscale → save**. SwiftUI/AppKit + Core ML. Offline image processing, no accounts, telemetry, runtime Python or third-party Swift dependencies. Apple Silicon, macOS 14+; native Liquid Glass controls on macOS 26+.

## Download and install

Download the ZIP from the artifact of a successful [macOS app run](https://github.com/GeraGCKM/DefUpscaler/actions). Unzip and drag `DefUpscaler.app` into Applications. Development builds are ad-hoc signed, not Developer ID signed/notarized. First launch may require approval under System Settings → Privacy & Security; do not disable Gatekeeper. Homebrew and production signing are planned for 1.0.

## Use

- Drop one or more images, double-click the preview area, or press ⌘O.
- Choose **Ilustración / anime**, **Fotografía**, or (when included) **Fotografía · textura**, then 2×, 4×, 8× or 16×.
- Press **Reescalar**. A batch runs sequentially; failures do not discard completed results.
- Toggle Original/Resultado to compare. The ⋯ menu offers 100% view, batch export, retry and cleanup. Appearance settings live only in the macOS application menu (⌘,).
- Press **Guardar** or use **Guardar todos**. Original files are protected. Existing results remain in the queue when you add images. Closing/resetting warns about unsaved results.

## Model and output contract

| Mode | Official pretrained model |
|---|---|
| Illustration/anime | RealESRGAN_x4plus_anime_6B (6 RRDB blocks) |
| Photography | RealESRGAN_x4plus at 4×, RealESRGAN_x2plus natively at 2× |
| Photography · texture (optional) | RealPLKSR / NomosWebPhoto, compiled 4× Core ML model by Philip Hofmann |

Illustration uses an official native 4× model. Photography at 2× prefers the official RealESRGAN_x2plus native 2× model; other photographic scales use 4×. **8× and 16× use a neural inference followed by Lanczos resizing**, not additional recovered detail or a native 16× model. The app does not claim that Lanczos itself adds AI detail. RealPLKSR is an additional restoration model; it may sharpen or synthesize textures, so compare the output with the source before relying on fine detail. Output is capped at 64 MP and a conservative memory estimate; some inputs/scales are rejected before decoding.

Output: **8-bit SDR sRGB PNG with alpha**. Color is converted to sRGB; original ICC profiles and other metadata are not copied. Alpha is resampled separately from neural RGB; no face reconstruction is applied. Images reported above 8-bit depth are rejected. HEIC with an HDR gain map uses its SDR base image; the HDR enhancement is not retained. This version does **not** claim end-to-end HDR output. Confirm suitability before using it for HDR/print workflows.

## Adaptive resources

No manual slow-mode toggle. A single prediction runs at a time. The governor starts at 64px core tiles, probes 128px and 192px after stable rows, and backs off under memory/thermal pressure or a sustained throughput regression. Real-ESRGAN patches include 16px of context on every side (96/160/224px model inputs). The optional RealPLKSR model uses fixed 512px input with 256/384px core regions (128/64px context respectively). Normal operation has no artificial sleep. Small-tile distress pacing and a thermal-critical pause protect responsiveness. Critical memory pressure aborts safely.

The goal is usable headroom, **not an exact 70–80% hardware cap**. Memory estimates and pressure events cannot guarantee that the OS never swaps or kills a process. Mac M5 browsing responsiveness and image-specific seam quality require hands-on acceptance testing. See [architecture](docs/ARCHITECTURE.md).

## Development and debugging

Use Xcode 26+ to build the Liquid Glass code; deployment remains macOS 14 with fallbacks.

```sh
swift test
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r scripts/requirements-model.txt
python scripts/convert_model.py
python scripts/fetch_realplksr.py  # optional; integrity-checked, skip if unavailable
bash scripts/package.sh
open build/DefUpscaler.app
```

CI verifies Swift tests, three Real-ESRGAN model profiles against PyTorch, image orientation/alpha/scales, packaging and signature integrity. Python dependencies are build-only. Models and CI actions have pinned checksums/commit IDs. Conversion provenance ships inside the app.

`swift run` opens the UI without bundled models; use the packaged app to test inference. Open `Package.swift` in Xcode and attach to the packaged process, or use LLDB. See [debugging](docs/DEBUGGING.md), [requirements](docs/REQUIREMENTS.md), and [changelog](CHANGELOG.md).

## Cleanup

The selected bundled models live in the app bundle. Unsaved outputs are in the app's temporary `DefUpscaler` directory; replacing the session, normal exit and the next launch after a crash clean them. Appearance is stored in the app's own preferences (`io.geragckm.DefUpscaler`). Exported images are retained. OS-managed Core ML caches, logs and quarantine metadata are not promised to disappear when the app is removed.

## Native navigation and accessibility

- Two-finger pan and pinch use AppKit NSScrollView, with magnification centered on the native gesture position.
- Double-click the loaded image for fit/actual-size, or double-click the empty surface to import. Use ⌘0 for fit, ⌘1 for actual pixels, ⌘O to import, ⌘S to save, ⇧⌘S to save all, ⌘D to switch original/result and ⌘, for settings.
- The comparison has one shared image coordinate system, a direct-draggable divider and rapid click-to-move. Reduce Motion removes its explicit transition; Reduce Transparency uses solid control backgrounds.
- Manual window resizing takes precedence over automatic aspect fitting. Full-screen and zoomed windows are not repositioned.

Real M5 performance, complex alpha halos, seam evaluation, image-specific faithfulness and VoiceOver behavior remain acceptance tasks, not assumed successes.
