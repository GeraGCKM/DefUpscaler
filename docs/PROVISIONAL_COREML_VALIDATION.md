# PROVISIONAL validation work — DefUpscaler 0.2

Status: experimental; **not a published release**. Branch: `codex/provisional-coreml-validation-0.2`.
The validated base is still the earlier 0.1 pipeline. Do not merge/publish until all model and app checks pass.

## Observed facts

- The official Real-ESRGAN anime 6B and photo x4plus checkpoint files are downloaded and verified by SHA-256. **They are not fine-tuned, modified or replaced**.
- On macOS GitHub Actions, the earlier Core ML model conversion completed, and the Python `coremltools.MLModel.predict` invocation crashed at runtime with `Trace/BPT trap: 5` (exit 133), even with `CPU_ONLY`. It is a native process trap, not a PyTorch weight-validation error.
- The previous attempted fixed-size 96/160/224 conversion was committed but its main-branch validation run never obtained a runner, so its correctness was unknown when this branch started.
- A Core ML or Python binding bug is a hypothesis, **not a confirmed upstream diagnosis**.

## Provisional diagnostic change

The Core ML conversion is still performed from the same official weights and same 4x RRDB architecture. Instead of calling the Core ML Python prediction bridge for numerical parity, Python now writes deterministic RGB PNG input fixtures and the independent PyTorch Float32 NCHW reference output for all six fixed-shape profiles (two samples each). The native macOS Swift tests then load the compiled Core ML models, perform actual CPU inference, and compare all pixels against that reference (mean absolute error at most 2/255). This is **not a skipped parity check**; a failing Swift/Core ML prediction or inaccurate result must still fail CI.

Existing end-to-end image tests, full model packaging, resource tests, UI capture and ZIP upload stay required. Results must be judged from the exact branch's completed GitHub Actions run. Once the platform issue is diagnosed, consider reverting this temporary validation architecture if a simpler direct check is demonstrably reliable.

## Release blockers

1. Successful build/test/conversion/numerical parity for both official models and all fixed profiles.
2. Native RGBA, orientation, output scales, model resources, and ZIP validation.
3. Hands-on testing on a real Apple Silicon Mac for responsiveness, alpha-edge halos, tile seams, cancellation and accessible UI.
4. No claim of native 8x/16x recovered detail or HDR preservation; the existing documented limitations remain.

Do not silently fall back to Lanczos as if it were neural inference, alter the upstream weights, or publish a failed build.
