# Architecture and scope

SwiftUI/AppKit is the native shell. Core ML handles a single bundled, converted Real-ESRGAN anime model. No Electron, web server, Python runtime, package manager, or third-party Swift dependency ships to the user.

A single main window owns an AppModel. The model invokes a serial UpscaleEngine actor. Decoding/inference/encoding are off the main actor. Preview decoding is bounded to 900px. Immutable JobPlan validates metadata before decoding, limits output to 64 megapixels and estimates buffers against one third of physical RAM. This is a conservative guard, not a measured working-set guarantee.

128px core tiles have 16px surrounding context; the fixed model input is 160×160 and output 640×640. Borders clamp to edge pixels. One prediction is active at a time; intermediate Core Image caches are disabled and autoreleased each tile. The app yields between tiles, slows under serious thermal state and pauses under critical state. Gentle mode inserts an 80ms delay per tile. It does not enforce a fictional 80% GPU cap. Benchmark before tuning tile size, overlap, compute units or pacing.

The initial build deliberately ships one illustration model. Add a photo model only after conversion, license and quality validation; do not label this model universal. Core ML uses the scheduler's available CPU/GPU/Neural Engine resources; `.all` is permission, not proof that every operator runs on the Neural Engine.

Model provenance is generated during conversion: upstream source URL, SHA-256, tool versions and numerical error against PyTorch on deterministic inputs. Currently the upstream release URL is fixed and the digest recorded, not pre-pinned to a separately verified trusted hash. Strict `weights_only` loading and state-key validation avoid executing serialized Python from weights. Release hardening should pin a reviewed checksum and CI actions by commit.

Aesthetic: system SF font, system window controls, 24pt margins, 16pt continuous rounded drop area, neutral system colors, one accent and no custom bundled fonts. Inspired by Antinote's simplicity, not a claim to reproduce its unpublished font/radius values.

Future iPhone: reuse geometry and Core ML processing, replace AppKit dialogs/previews with PhotosPicker/Files, add lifecycle handling and lower limits. Future Windows full Rust: separate Rust UI and Burn/wgpu-compatible model importer; reuse model weights, test fixtures and contracts. It is a separate validated implementation, not a compilation flag for SwiftUI.
