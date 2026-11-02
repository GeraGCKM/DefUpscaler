# DefUpscaler

Native, offline macOS image upscaler. SwiftUI + Core ML, no runtime package dependencies, no accounts or telemetry. Initial target: Apple Silicon, macOS 14 or later.

**Version 0.1 is an experimental illustration/anime build**, using RealESRGAN_x4plus_anime_6B. 4× means four times the width and height; 2× runs the 4× model and downsamples. Photos, alpha preservation, HDR, batches, and 16× are not implemented. Transparency is flattened onto white; output is an sRGB PNG. Embedded metadata is not copied.

## Install

Open [Actions](https://github.com/GeraGCKM/DefUpscaler/actions), choose a successful **macOS app** run, download `DefUpscaler-macOS-AppleSilicon`, unzip the artifact and the app ZIP inside it, and drag `DefUpscaler.app` into Applications. A GitHub login may be needed to download artifacts.

This development build is ad-hoc signed, not Developer ID signed or notarized. macOS may require explicitly approving the first launch under System Settings → Privacy & Security. Do not disable Gatekeeper. Production signing is a separate distribution step.

Drop an image, choose 2× or 4×, press **Mejorar**, then **Guardar**. Nothing is uploaded. The network is only used by the build server to obtain build tools and original weights.

## Development

Open `Package.swift` in Xcode, or on a Mac:

```sh
swift test
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r scripts/requirements-model.txt
python scripts/convert_model.py
bash scripts/package.sh
open build/DefUpscaler.app
```

`swift run` launches the UI but cannot find the bundled model; use the packaged app for inference. To debug it, run `lldb build/DefUpscaler.app/Contents/MacOS/DefUpscaler`, set a breakpoint, then `run`. Xcode can attach to the packaged process by name.

- `UpscaleCore/JobPlan`: allocation limits and deterministic tile geometry.
- `UpscaleCore/UpscaleEngine`: model loading, decoding, tile inference, cancellation and PNG encoding, isolated in an actor.
- `DefUpscaler/AppModel`: main-actor state and file dialogs.
- `DefUpscaler/DefUpscalerApp`: native UI and app lifecycle.
- `scripts/convert_model.py`: strict weight loading and Core ML/PyTorch numerical check; Python is build-only.

See [debugging](docs/DEBUGGING.md) and [design decisions](docs/ARCHITECTURE.md).

## Cleanup

The app stores no downloaded models, preferences or input history. The model lives inside the app bundle. Unsaved outputs live in its temporary `DefUpscaler` directory and are deleted when replaced, cleared, on normal exit, and on the next launch after a crash. Use **Borrar sesión y temporales**, quit, then move the app to Trash. Saved outputs belong to you and are retained. OS-managed Core ML caches, logs and quarantine records are outside the app's cleanup control; no claim of literally zero system traces is made.

## Validation status

CI checks compilation, tile/limit tests, conversion parity, packaging and signature integrity. Real-image seam quality, color fidelity, cancellation latency, VoiceOver and M5 memory/thermal performance still require hands-on Mac acceptance testing. Passing CI is not a performance certification.
