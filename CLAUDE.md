# Clarion

Native macOS app (Swift 5.9+, SwiftUI, AVFoundation, Metal/MetalFX, VideoToolbox) that live-displays
a console feed from a USB HDMI capture card with the lowest latency possible. No third-party
dependencies, no drivers, sandboxed. macOS 14+, Apple Silicon first, Intel must still work.

- Frame path and what has been built: `docs/PLAN.md`. User-facing usage: `README.md`.
- Build: `xcodebuild -project Clarion.xcodeproj -scheme Clarion -derivedDataPath build build`. Shareable universal app: `scripts/export.sh`.
- Open `Clarion.xcodeproj` (Xcode 16+). It uses synchronized folders: any file in `Clarion/` is in the target automatically.
- `Config/` holds Info.plist and entitlements. It is referenced only by build settings, so it is not compiled.

## Latency rules (do not regress)
- Capture uncompressed (420v, then YUY2/UYVY). MJPEG only when the user picks it.
- `alwaysDiscardsLateVideoFrames = true`; frames are handled on a dedicated `.userInteractive` serial queue.
- Zero copy: CVPixelBuffer → CVMetalTextureCache → MTLTexture. No CPU copies, no CIImage.
- Render on frame arrival; max 1 frame in flight; CAMetalLayer `maximumDrawableCount = 2`, `framebufferOnly = true`.
  Exception: frame generation uses 3 drawables and presents from `presentQueue`, never blocking the capture thread
  (measured on M3: 2 drawables or presenting on the capture thread gives 30 fps in → only ~40 out). When it can't
  interpolate (source already fast, unsupported size) frames take the normal direct path.
  Don't use `CAMetalDisplayLink`: it picks frames 3 refreshes ahead (+30–45 ms) and any other `nextDrawable` then throws.
- Frame generation's delay is held down by `Renderer.LatencyGovernor`: output is made at least as fast as the screen
  shows it, so a queued frame never drains by itself (M3, 60 Hz: 87–112 ms without it, ~55–78 with). It empties the
  queue once to learn the floor, then skips single generated frames when the delay's 20th percentile is a refresh above
  it. Lessons from a real Remote Play stream: judging one skip by "did the delay fall" fails with a full queue; judging
  by the average delay over-skips (6–18 frames/s), because streams deliver ~15% of frames a refresh early or late and
  each early one queues its neighbours briefly.
- No in-between frame when two real frames are under 1.5 refreshes apart (no refresh to show it in), unless the
  display queue is empty and `steadyFrameGeneration` is on: then it may wait there to cover the next late frame
  (real stream: empty refreshes 2.8 → 0.9 a second, typical delay still 61 ms).
- Tried and dropped: two in-between frames (⅓, ⅔) for a frame that arrives a refresh late. A queue model predicted no
  empty refreshes; on screen it was worse (54–58 fps at ~85 ms with drops vs 56–60 at ~50), since three presents in a
  row exceed CAMetalLayer's three drawables and the present thread blocks. Models of the display queue are optimistic.
- The real frame follows its generated frame by whole refreshes minus a quarter (`hold`), never by the smoothed half
  period: 17–18 ms on a 60 Hz screen means two refreshes, pairs then take three, and the queue saturates. Stage timing on
  the real stream after this fix: 3 ms handover + ~10 ms drawables + ~48 ms from commit to screen = 60 ms, steady. Don't remove any of this or "fix" the occasional skipped frame.
- `RepeatDetector` learns the stream's real/repeat rhythm per refresh slot (Remote Play: real frames change 0.20–0.36,
  touched-up repeats 0–0.13 on the probe scale). A fixed "30% of a real frame" rule let enough repeats through to read
  a 30 fps game as 32–40 fps.
- Still-pixel lock (`updateStillness` / `lockStill`): pixels unchanged for 5 real frames are taken from the real frame
  in generated frames, at the real frame's size. Fewer than ~4 frames locks moving texture by coincidence and costs detail.
- `VTFrameProcessor` can't be restarted after `endSession` (crashes in `process`): make a new one per session.
- Hide the SwiftUI overlay view entirely when nothing is shown, so nothing is composited over the video.
- When nothing needs it, keep the single-pass path (conversion straight into the drawable). Extra passes only for upscale/sharpen.
- Screenshots and recording (`Recorder`) get frames through `Renderer.setFrameSink`. The sink is set only while one of
  them wants frames; the picture is then drawn into a BGRA buffer and copied to the drawable (one extra pass). Never leave it set.
- The live stream (`Broadcaster`) runs on its own queue: nothing of it on the capture thread or `presentQueue`. It takes
  frames through the same `setFrameSink` as the recorder; the sink is unset when neither wants frames.
- While live, the stats overlay is drawn on a copy (`sharesFrames`), so it can be in a recording and never in the stream.
- Hardware H.264 encoder only, no software fallback. It ignores bitrate caps on this Mac; the broadcaster holds the
  bitrate by skipping frames.
- Stream keys live only in the keychain: never in UserDefaults, logs or error text.
- The LIVE badge goes through `updateOverlayVisibility` like the other badges: the overlay view stays hidden when
  nothing is shown. Its timer exists only while live.
- Frame generation APIs are macOS 26+: keep them behind `#available` (the interpolator is stored untyped in Renderer) and hide the toggle when unsupported.

## Checking changes without Xcode
Type-check: `swiftc -typecheck -parse-as-library -swift-version 5 -sdk $(xcrun --show-sdk-path) -target arm64-apple-macos14.0 Clarion/*.swift`
(repeat with `x86_64-apple-macos14.0` for Intel). Shaders can be checked with `MTLDevice.makeLibrary(source:)`.
Stream checks: `scripts/check-stream.sh` must print `all checks passed`. Settings view state lives in an ObservableObject,
not `@State`, because plain swiftc can't type-check `@State` with this SDK.
