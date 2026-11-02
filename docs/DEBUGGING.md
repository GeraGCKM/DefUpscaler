# Debugging

Run `swift test` before pushing. CI separates Swift tests, dependency installation, model conversion/parity and packaging, so failures identify the stage.

Use macOS Console, filter subsystem `io.geragckm.DefUpscaler`, or:

```sh
log stream --level info --predicate 'subsystem == "io.geragckm.DefUpscaler"'
```

Logs record scale, tile count, duration and failure description. They do not intentionally record image bytes or filenames; review system error messages before sharing logs. No analytics service receives logs.

Attach Xcode/Instruments to the packaged app. Recommended instruments: Allocations, Time Profiler, Swift Concurrency and Core ML. MainActor owns UI; inference actor serializes predictions. Cancellation is checked between predictions and cannot interrupt an in-flight synchronous Core ML call. A thermal-critical pause remains cancellable. Critical memory pressure aborts between predictions; it cannot guarantee prevention of all OS memory kills.

Bug reports: commit/run URL, macOS version, chip and RAM, input pixel dimensions/format, scale, gentle mode, exact error, expected vs actual result. Provide a non-sensitive sample only if needed. Include `model-provenance.json` from the artifact to identify converted weights.

Manual acceptance before a release:

1. Process odd-sized images (259×133), 1×1, EXIF rotated JPEG and saturated RGB stripes. Confirm exact output dimensions and orientation.
2. Inspect a line crossing a tile boundary at 100%; compare against full-frame PyTorch. The 16px overlap is a starting point, not a guarantee of invisible seams for all inputs.
3. Verify transparent input is intentionally white-backed; compare colors in Preview.
4. Cancel early/late, close while running, retry, export over an existing file, cancel the save dialog, reopen after forced termination.
5. Reject excessive dimensions before full decode. Test under real memory pressure, monitor peaks and responsiveness while other applications run.
6. Check keyboard-only use, VoiceOver, dark/light appearance and increased contrast.

Known gaps: no automated GUI test, no bundled golden image corpus, no validated full-frame-vs-tiled quality benchmark yet, no Developer ID notarization. 2× uses per-tile high-quality downsampling; inspect boundaries before relying on it for print output.
