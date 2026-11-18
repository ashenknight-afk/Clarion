import Foundation
import CoreMedia
import CoreVideo

/// Thread-safe collector for encoder output.
private final class FrameLog {
    private let lock = NSLock()
    private var items: [StreamVideoEncoder.Frame] = []
    func add(_ frame: StreamVideoEncoder.Frame) { lock.lock(); items.append(frame); lock.unlock() }
    var frames: [StreamVideoEncoder.Frame] { lock.lock(); defer { lock.unlock() }; return items }
}

/// A BGRA IOSurface-backed buffer holding a diagonal gradient that moves with `index`, plus noise
/// so the encoder has detail to spend its bit budget on.
private func gradientBuffer(width: Int, height: Int, index: Int) -> CVPixelBuffer? {
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
    ]
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    var seed = UInt32(truncatingIfNeeded: index &* 2_654_435_761) | 1
    for y in 0..<height {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Int(seed >> 30)
            let phase = x + y + index * 12
            row[x * 4 + 0] = UInt8(truncatingIfNeeded: phase / 2 + noise)
            row[x * 4 + 1] = UInt8(truncatingIfNeeded: (x - index * 7) / 3 + noise * 2)
            row[x * 4 + 2] = UInt8(truncatingIfNeeded: (y + index * 5) / 2)
            row[x * 4 + 3] = 255
        }
    }
    return buffer
}

/// Encodes `count` frames at 60 fps and returns what came out. Buffers are made up front so the
/// encoder is not starved while the test paints.
private func encodeRun(count: Int, bitrate: Int, forceKeyframeAt: Int? = nil) -> [StreamVideoEncoder.Frame]? {
    let log = FrameLog()
    guard let encoder = StreamVideoEncoder(width: 1920, height: 1080, bitrate: bitrate, frameRate: 60, onFrame: { log.add($0) }) else { return nil }
    // A few distinct buffers reused in turn keeps memory and paint time low.
    let pool = (0..<8).compactMap { gradientBuffer(width: 1920, height: 1080, index: $0) }
    guard pool.count == 8 else { return nil }
    for i in 0..<count {
        encoder.encode(pool[i % pool.count], at: CMTime(value: CMTimeValue(i), timescale: 60), forceKeyframe: i == forceKeyframeAt)
    }
    encoder.invalidate()
    return log.frames
}

func videoEncoderChecks() {
    guard StreamVideoEncoder.hardwareAvailable(width: 1920, height: 1080) else {
        print("video encoder checks skipped: no hardware H.264 encoder for 1920x1080")
        return
    }

    check("encoder outputs 300 frames in input order with keyframes and parameter sets") {
        let frames = try encodeRun(count: 300, bitrate: 6_000_000).unwrapped("encoder not created")
        try expect(frames.count == 300, "got \(frames.count) frames")
        try expect(frames[0].keyframe, "first frame is not a keyframe")
        try expect(frames[0].sps?.isEmpty == false && frames[0].pps?.isEmpty == false, "first keyframe lacks SPS/PPS")
        var last = -1
        var lastKey = 0
        for (i, frame) in frames.enumerated() {
            let t = Int(frame.time.value)
            try expect(t > last, "time \(t) after \(last) at \(i)")
            last = t
            try expect(frame.avcc.count > 4, "empty frame \(i)")
            let length = frame.avcc.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            try expect(length > 0 && length <= frame.avcc.count - 4, "bad length prefix at \(i)")
            if frame.keyframe {
                try expect(i - lastKey <= 120, "keyframes \(i - lastKey) frames apart")
                lastKey = i
            }
        }
        try expect(299 - lastKey <= 120, "no keyframe in the last stretch")
    }

    check("forceKeyframe makes that frame a keyframe") {
        let frames = try encodeRun(count: 100, bitrate: 6_000_000, forceKeyframeAt: 50).unwrapped("encoder not created")
        try expect(frames.count == 100, "got \(frames.count) frames")
        try expect(frames[50].keyframe, "frame 50 is not a keyframe")
    }

    check("encoder stays near the bitrate over 5 seconds") {
        let frames = try encodeRun(count: 300, bitrate: 6_000_000).unwrapped("encoder not created")
        let total = frames.reduce(0) { $0 + $1.avcc.count }
        try expect(total >= 1_500_000 && total <= 5_000_000, "total \(total) bytes")
    }

    check("encode after invalidate does nothing") {
        let log = FrameLog()
        let encoder = try StreamVideoEncoder(width: 1920, height: 1080, bitrate: 6_000_000, frameRate: 60, onFrame: { log.add($0) }).unwrapped("encoder not created")
        let buffer = try gradientBuffer(width: 1920, height: 1080, index: 0).unwrapped("no buffer")
        encoder.encode(buffer, at: .zero)
        encoder.invalidate()
        let count = log.frames.count
        encoder.encode(buffer, at: CMTime(value: 1, timescale: 60))
        Thread.sleep(forTimeInterval: 0.2)
        try expect(log.frames.count == count, "frames arrived after invalidate")
    }
}

private extension Optional {
    func unwrapped(_ message: String) throws -> Wrapped {
        guard let self else { throw CheckFailure(description: message) }
        return self
    }
}
