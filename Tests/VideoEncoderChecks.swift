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

private let width = 1920
private let height = 1080

/// A row of BGRA pixels, much wider than the picture: a ramp plus noise. Rows are copied out of
/// it at an offset that moves every frame, so the picture moves and no two frames repeat.
/// `noiseShift` sets how busy it is: 31 is nearly flat, 24 is close to white noise.
private func noiseRow(noiseShift: UInt32) -> [UInt8] {
    var seed: UInt32 = 12345
    var row = [UInt8](repeating: 255, count: (width + 4096) * 4)
    for x in 0..<(width + 4096) {
        for channel in 0..<3 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            row[x * 4 + channel] = UInt8(truncatingIfNeeded: x / 8 + Int(seed >> noiseShift))
        }
    }
    return row
}

/// A new BGRA IOSurface-backed buffer for frame `index`.
private func movingBuffer(from row: [UInt8], index: Int) -> CVPixelBuffer? {
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    row.withUnsafeBytes { source in
        for y in 0..<height {
            let offset = ((y * 13 + index * 37) % 4000) * 4
            memcpy(base + y * stride, source.baseAddress! + offset, width * 4)
        }
    }
    return buffer
}

private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { Thread.sleep(forTimeInterval: 0.002) }
}

private struct Run {
    let frames: [StreamVideoEncoder.Frame]
    let dropped: Int
    var totalBytes: Int { frames.reduce(0) { $0 + $1.avcc.count } }
    /// Most bytes in any one second of presentation time.
    var worstSecond: Int {
        var worst = 0
        var start = 0
        var sum = 0
        for frame in frames {
            sum += frame.avcc.count
            while frame.time.seconds - frames[start].time.seconds >= 1 {
                sum -= frames[start].avcc.count
                start += 1
            }
            worst = max(worst, sum)
        }
        return worst
    }
}

/// Encodes `count` frames at 60 fps and returns what came out once the encoder has finished.
private func encodeRun(count: Int, bitrate: Int = 6_000_000, noiseShift: UInt32, forceKeyframeAt: Int? = nil) -> Run? {
    let log = FrameLog()
    guard let encoder = StreamVideoEncoder(width: width, height: height, bitrate: bitrate, frameRate: 60, onFrame: { log.add($0) }) else { return nil }
    let row = noiseRow(noiseShift: noiseShift)
    for i in 0..<count {
        guard let buffer = movingBuffer(from: row, index: i) else { return nil }
        // Capture arrives every 16 ms; a little pacing keeps the checks short but not a flood.
        Thread.sleep(forTimeInterval: 0.004)
        encoder.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60), forceKeyframe: i == forceKeyframeAt)
        // The first frame's latency is the encoder's warm-up, not steady state: wait it out.
        if i == 0 { waitUntil(timeout: 3) { !log.frames.isEmpty } }
    }
    encoder.invalidate()
    return Run(frames: log.frames, dropped: encoder.droppedFrames)
}

func videoEncoderChecks() {
    guard StreamVideoEncoder.hardwareAvailable(width: 1920, height: 1080) else {
        print("video encoder checks skipped: no hardware H.264 encoder for 1920x1080")
        return
    }

    check("encoder outputs 300 frames in input order with keyframes and parameter sets") {
        let run = try encodeRun(count: 300, noiseShift: 31).unwrapped("encoder not created")
        let frames = run.frames
        try expect(frames.count == 300, "got \(frames.count) frames")
        try expect(run.dropped == 0, "dropped \(run.dropped) frames")
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
        let run = try encodeRun(count: 100, noiseShift: 31, forceKeyframeAt: 50).unwrapped("encoder not created")
        try expect(run.frames.count == 100, "got \(run.frames.count) frames")
        try expect(run.frames[50].keyframe, "frame 50 is not a keyframe")
    }

    // The hardware encoder overshoots its data rate on busy pictures, so these hold the guard to it.
    // Not covered: near-white noise (shift 24), where one key frame alone is ~900 KB and no
    // frame dropping can keep a second under the limit.
    for (shift, name) in [(UInt32(28), "busy"), (UInt32(26), "very busy")] {
        check("encoder holds 6 Mbps on \(name) input") {
            let run = try encodeRun(count: 300, noiseShift: shift).unwrapped("encoder not created")
            if shift == 28 {
                try expect(run.totalBytes >= 1_500_000 && run.totalBytes <= 5_000_000, "total \(run.totalBytes) bytes")
            }
            try expect(run.frames.count > 5, "only \(run.frames.count) frames")
            try expect(Double(run.worstSecond) <= 1.3 * 750_000, "worst second \(run.worstSecond) bytes")
            try expect(run.frames.count + run.dropped == 300, "frames \(run.frames.count) + dropped \(run.dropped)")
        }
    }

    check("encode after invalidate does nothing") {
        let log = FrameLog()
        let encoder = try StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { log.add($0) }).unwrapped("encoder not created")
        let row = noiseRow(noiseShift: 31)
        let buffer = try movingBuffer(from: row, index: 0).unwrapped("no buffer")
        encoder.encode(buffer, at: .zero)
        encoder.invalidate()
        let count = log.frames.count
        try expect(!encoder.encode(buffer, at: CMTime(value: 1, timescale: 60)), "encode accepted a frame after invalidate")
        Thread.sleep(forTimeInterval: 0.2)
        try expect(log.frames.count == count, "frames arrived after invalidate")
    }

    check("releasing encoders with frames in flight does not deadlock") {
        let done = DispatchSemaphore(value: 0)
        let row = noiseRow(noiseShift: 28)
        DispatchQueue.global().async {
            for _ in 0..<50 {
                var encoder: StreamVideoEncoder? = StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { _ in })
                for i in 0..<4 {
                    if let buffer = movingBuffer(from: row, index: i) {
                        encoder?.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60))
                    }
                }
                encoder = nil
            }
            done.signal()
        }
        try expect(done.wait(timeout: .now() + 20) == .success, "timed out")
    }

    check("onFrame invalidating while another thread encodes does not deadlock") {
        let done = DispatchSemaphore(value: 0)
        let row = noiseRow(noiseShift: 31)
        DispatchQueue.global().async {
            for _ in 0..<10 {
                var encoder: StreamVideoEncoder?
                encoder = StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { _ in
                    encoder?.invalidate()
                })
                // Keep encoding while the first output invalidates the encoder.
                for i in 0..<30 {
                    if let buffer = movingBuffer(from: row, index: i) {
                        encoder?.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60))
                    }
                }
                encoder?.invalidate()
                encoder = nil
            }
            done.signal()
        }
        try expect(done.wait(timeout: .now() + 20) == .success, "timed out")
    }

    check("a keyframe the guard dropped is delivered on the next frame") {
        // Busy input so the guard is dropping; ask for a keyframe on every dropped-prone frame.
        let log = FrameLog()
        guard let encoder = StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { log.add($0) }) else { throw CheckFailure(description: "encoder not created") }
        let row = noiseRow(noiseShift: 26)
        var refused = -1
        for i in 0..<240 {
            let buffer = try movingBuffer(from: row, index: i).unwrapped("no buffer")
            if i == 0 { encoder.encode(buffer, at: .zero); waitUntil(timeout: 3) { !log.frames.isEmpty }; continue }
            let accepted = encoder.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60), forceKeyframe: refused < 0)
            if !accepted && refused < 0 { refused = i }
            if accepted && refused >= 0 {
                encoder.invalidate()
                let frame = log.frames.last
                try expect(frame?.time == CMTime(value: CMTimeValue(i), timescale: 60) && frame?.keyframe == true, "kept request not applied")
                return
            }
        }
        try expect(refused >= 0, "guard never dropped a frame")
        throw CheckFailure(description: "no frame admitted after the dropped keyframe request")
    }

    check("onFrame may invalidate its own encoder") {
        let done = DispatchSemaphore(value: 0)
        var encoder: StreamVideoEncoder?
        let row = noiseRow(noiseShift: 31)
        encoder = StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { _ in
            encoder?.invalidate()
            done.signal()
        })
        let buffer = try movingBuffer(from: row, index: 0).unwrapped("no buffer")
        try expect(encoder?.encode(buffer, at: .zero) == true, "encode refused")
        try expect(done.wait(timeout: .now() + 10) == .success, "timed out")
        encoder = nil
    }
}

private extension Optional {
    func unwrapped(_ message: String) throws -> Wrapped {
        guard let self else { throw CheckFailure(description: message) }
        return self
    }
}
