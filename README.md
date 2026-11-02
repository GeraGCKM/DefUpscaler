# DefUpscaler 0.2

A small native macOS app for **drop → choose mode and scale → upscale → save**. SwiftUI/AppKit + Core ML. Offline image processing, no accounts, telemetry, runtime Python or third-party Swift dependencies. Apple Silicon, macOS 14+; native Liquid Glass controls on macOS 26+.

## Download and install

Download the ZIP from the artifact of a successful [macOS app run](https://github.com/GeraGCKM/DefUpscaler/actions). Unzip and drag `DefUpscaler.app` into Applications. Development builds are ad-hoc signed, not Developer ID signed/notarized. First launch may require approval under System Settings → Privacy & Security; do not disable Gatekeeper. Homebrew and production signing are planned for 1.0.

## Use

- Drop one or more images, double-click the preview area, or press ⌘O.
- Choose **Ilustración / anime** or **Fotografía**, then 2×, 4×, 8× or 16×.
- Press **Reescalar**. A batch runs sequentially; failures do not discard completed results.
- Toggle Original/Resultado to compare. The ⋯ menu offers 100% view, batch export, retry, cleanup and appearance settings.
- Press **Guardar** or use **Guardar todos**. Original files are protected. Existing results remain in the queue when you add images. Closing/resetting warns about unsaved results.

## Model and output contract

| Mode | Official pretrained model |
|---|---|
| Illustration/anime | RealESRGAN_x4plus_anime_6B (6 RRDB blocks) |
| Photography | RealESRGAN_x4plus (23 RRDB blocks) |

Both models infer at **4× each side**. 2× downsamples the result. **8× and 16× use 4× neural inference plus Lanczos resizing**, not additional recovered detail or a native 16× model. The app shows this distinction. Output is capped at 64 MP and a conservative memory estimate; some inputs/scales are rejected before decoding.

Output: **8-bit SDR sRGB PNG with alpha**. Color is converted to sRGB; original ICC profiles and other metadata are not copied. Alpha is resampled separately from neural RGB; no face reconstruction is applied. Images reported above 8-bit depth are rejected. HEIC with an HDR gain map uses its SDR base image; the HDR enhancement is not retained. This version does **not** claim end-to-end HDR output. Confirm suitability before using it for HDR/print workflows.

## Adaptive resources

No manual slow-mode toggle. A single prediction runs at a time. The governor starts at 64px core tiles, probes 128px and 192px after stable rows, and backs off under memory/thermal pressure or a sustained throughput regression. Input patches include 16px of context on every side (96/160/224px model inputs). Normal operation has no artificial sleep. Small-tile distress pacing and a thermal-critical pause protect responsiveness. Critical memory pressure aborts safely.

The goal is usable headroom, **not an exact 70–80% hardware cap**. Memory estimates and pressure events cannot guarantee that the OS never swaps or kills a process. Mac M5 browsing responsiveness and image-specific seam quality require hands-on acceptance testing. See [architecture](docs/ARCHITECTURE.md).

## Development and debugging

Use Xcode 26+ to build the Liquid Glass code; deployment remains macOS 14 with fallbacks.

```sh
swift test
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r scripts/requirements-model.txt
python scripts/convert_model.py
bash scripts/package.sh
open build/DefUpscaler.app
```

CI verifies Swift tests, both models at all three input sizes against PyTorch, image orientation/alpha/scales, packaging and signature integrity. Python dependencies are build-only. Models and CI actions have pinned checksums/commit IDs. Conversion provenance ships inside the app.

`swift run` opens the UI without bundled models; use the packaged app to test inference. Open `Package.swift` in Xcode and attach to the packaged process, or use LLDB. See [debugging](docs/DEBUGGING.md), [requirements](docs/REQUIREMENTS.md), and [changelog](CHANGELOG.md).

## Cleanup

The two models live in the app bundle. Unsaved outputs are in the app's temporary `DefUpscaler` directory; replacing the session, normal exit and the next launch after a crash clean them. Appearance is stored in the app's own preferences (`io.geragckm.DefUpscaler`). Exported images are retained. OS-managed Core ML caches, logs and quarantine metadata are not promised to disappear when the app is removed.
