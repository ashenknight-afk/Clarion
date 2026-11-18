# Clarion: frame path and build notes

Shows a console full screen on a Mac with the lowest delay it can, then upscales and sharpens the
picture. First goal: under 100 ms glass to glass. Second: a sharper image.

## Frame path

```
capture card ─▶ AVCaptureVideoDataOutput (420v / YUY2 / UYVY, late frames discarded)
streaming app ─▶ ScreenCaptureKit window capture (420v, 16:9 crop of the window)
        ─▶ CVMetalTextureCache (zero copy, IOSurface-backed)
        ─▶ [frame generation: 420v copy → VTFrameProcessor → still-pixel lock]
        ─▶ YCbCr → RGB ─▶ [MetalFX / Lanczos upscale] ─▶ [CAS sharpen] into the Fit/Fill/Stretch viewport
        ─▶ CAMetalLayer (2 drawables, framebufferOnly, V-Sync toggle) ─▶ present
```

Without frame generation each frame renders on the capture thread the moment it arrives. At most
one frame is in flight; if the GPU is still busy, the new frame is dropped, not queued.

With frame generation the capture thread only queues GPU work. A separate queue presents the
generated frame, then the real one a refresh later, from three drawables.

## Built

1. Capture, zero-copy display, display detection, stats overlay.
2. Upscaling: MetalFX spatial, separable Lanczos-3 fallback.
3. Contrast adaptive sharpening.
4. Capture-card audio passthrough in its own session.
5. Frame generation (macOS 26+), off by default: repeat detection, still-pixel lock, latency governor.
6. Latency test, universal build script.
7. Window capture for streaming apps.
8. Screenshots and recording of the enhanced picture with the source's sound.

## Looked at and not built

Checked on an M3, macOS 27:

- Apple's low-latency super resolution (`VTLowLatencySuperResolutionScaler`) takes at most 1280×1280 input
  (720p ×1.5 or 540p ×2), about 2–3 ms a frame. Useless for a 1080p source; a possible upscaler choice for 720p ones.
- Apple's temporal noise filter only accepts lossless-compressed pixel formats (`&8v0`…), not plain 420v, and
  targets camera noise, not stream compression artefacts.
- Two generated frames for a frame that arrives a refresh late: worse on screen than one. See `CLAUDE.md`.
- Open: local video files through the same pipeline, HDR output, deblocking before sharpening.
