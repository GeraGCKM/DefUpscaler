# Working on DefUpscaler

- Preserve the native macOS shell and offline runtime. Do not add a web view, telemetry, runtime Python, or a package dependency without a demonstrated need.
- UI and dialogs belong on MainActor; image processing belongs in UpscaleCore. Keep errors actionable and keep private image contents/paths out of intentional logs.
- Validate dimensions before allocation. Do not remove cancellation, thermal or memory checks to improve a benchmark.
- Do not replace neural inference with interpolation while presenting it as AI. Document model, scale, alpha and color-space limitations honestly.
- Run `swift test` on macOS. Changes to conversion/inference also need the conversion parity gate and `DEFUPSCALER_TEST_MODEL=... swift test --filter EngineIntegrationTests`.
- Never claim a Mac build/test passed when only syntax checks ran on Linux. Record pending manual performance and quality acceptance checks.
- Keep build dependencies out of the .app. Preserve third-party notices and model provenance when packaging.
- Do not commit images from users, model weights, build products, credentials or signing certificates.
