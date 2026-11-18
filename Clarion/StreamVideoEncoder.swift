import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Hardware H.264 encoder for the stream. Takes BGRA buffers, emits AVCC frames (4-byte length
/// prefixed NAL units) with the parameter sets on keyframes. Never falls back to software.
final class StreamVideoEncoder {
    struct Frame {
        let avcc: Data
        let keyframe: Bool
        let time: CMTime
        let sps: Data?
        let pps: Data?
    }

    private static let cacheLock = NSLock()
    private static var availability: [String: Bool] = [:]

    /// Tries to create a hardware-only session at this size. The answer is cached per size.
    static func hardwareAvailable(width: Int, height: Int) -> Bool {
        let key = "\(width)x\(height)"
        cacheLock.lock()
        if let known = availability[key] { cacheLock.unlock(); return known }
        cacheLock.unlock()
        let session = makeSession(width: width, height: height)
        if let session { VTCompressionSessionInvalidate(session) }
        let available = session != nil
        cacheLock.lock()
        availability[key] = available
        cacheLock.unlock()
        return available
    }

    private static func makeSession(width: Int, height: Int) -> VTCompressionSession? {
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        return status == noErr ? session : nil
    }

    /// Holds the stream to the target byte rate, which the hardware encoder does not (measured:
    /// it overshoots its average bitrate and data rate limit by 50% and more on busy pictures and
    /// ignores CBR, QP limits and quality). It drops input frames rather than letting a burst out.
    ///
    /// Invariant: a frame is admitted only if the bytes output in the last second of presentation
    /// time, plus every frame in flight costed at the larger of its reservation and the current
    /// estimate for its kind, plus the frame itself (a keyframe with a quarter more), fit the
    /// target. Estimates are the largest frame of that kind in the last second (a keyframe: the
    /// last keyframe, never less than a delta), falling back to the largest frame there is. So a
    /// second goes over only by what frames outgrow their estimates. A lone frame (nothing in the window or in
    /// flight) is always admitted: a frame bigger than the budget would otherwise stop the stream.
    ///
    /// The window alone lets a burst through at the start of each second and refuses the rest,
    /// so delta frames are also paced by a credit charged with their actual size. It refills at
    /// the target less a keyframe (one comes every 2 s, so every second is within a second of
    /// one). The pace yields after three drops in a row, so viewers see a lower frame rate rather
    /// than a frozen picture; the window never yields, since holding the rate comes first.
    /// Possible later improvement: lower the session's average bitrate while shedding, so the
    /// encoder stops spending the dropped frames' budget on the frames it gets.
    private struct RateGuard {
        let target: Double
        /// Seconds after a keyframe when the guard forces the next one, a little before the
        /// encoder's own 2 s limit would, so the kind of every frame is known when it is costed.
        let keyframeInterval: Double
        private var window: [(time: Double, bytes: Int, keyframe: Bool)] = []
        private var windowBytes = 0
        private var inFlight: [(keyframe: Bool, reserved: Int, charged: Double)] = []
        private var largestSeen: Int?
        private var lastDeltaBytes = 0
        private var lastKeyframeBytes: Int?
        private var lastKeyframeTime: Double?
        private var lastTime: Double?
        private var credit = 0.0
        private var dropsInRow = 0
        /// Set while a keyframe is wanted and not yet handed to the encoder.
        private var keyframePending = false

        init(target: Double, frameRate: Int) {
            self.target = target
            keyframeInterval = 2 - 1.5 / Double(max(frameRate, 1))
        }

        private func cost(keyframe: Bool) -> Int? {
            let deltas = window.lazy.filter { !$0.keyframe }.map(\.bytes).max()
            let delta = deltas ?? window.lazy.map(\.bytes).max() ?? largestSeen
            guard keyframe else { return delta }
            guard let last = lastKeyframeBytes ?? largestSeen else { return delta }
            return max(last, delta ?? 0)
        }

        /// Returns whether the frame should be a keyframe, or nil to drop it. An admitted frame
        /// must be followed by `sent` or `failed`.
        mutating func admit(at time: Double, forceKeyframe: Bool) -> Bool? {
            if let last = lastTime, time < last {
                // Input time went backwards: the old window says nothing about the new stretch.
                window.removeAll()
                windowBytes = 0
                lastKeyframeTime = nil
                credit = 0
            }
            let elapsed = lastTime.map { min(max(time - $0, 0), 1) } ?? 0
            lastTime = time
            while let first = window.first, first.time <= time - 1 {
                windowBytes -= first.bytes
                window.removeFirst()
            }
            if forceKeyframe || lastKeyframeTime.map({ time - $0 >= keyframeInterval }) ?? true {
                keyframePending = true
            }
            let keyframe = keyframePending
            // Every second is within a second of a keyframe, so deltas get what one leaves, less
            // a little so the window itself rarely has to refuse a frame (that is what makes runs).
            let pace = max(target - Double(cost(keyframe: true) ?? 0), target / 4) * 0.95
            credit = min(credit + pace * elapsed, pace / 10)

            let lone = window.isEmpty && inFlight.isEmpty
            guard let candidate = cost(keyframe: keyframe) else {
                // Nothing has come out yet, so no size is known: one frame at a time.
                guard lone else { return drop() }
                inFlight.append((keyframe, 0, 0))
                dropsInRow = 0
                return keyframe
            }
            if !lone {
                if !keyframe && credit < 0 && dropsInRow < 3 { return drop() }
                let pending = inFlight.reduce(0) { $0 + max($1.reserved, cost(keyframe: $1.keyframe) ?? 0) }
                // A keyframe needs a quarter more room: fed sparsely, the encoder spends what drops
                // left unused on it (measured: 493 KB after a 368 KB one).
                let growth = keyframe ? Double(candidate) / 4 : 0
                if Double(windowBytes + pending + candidate) + growth > target { return drop() }
            }
            let charge = keyframe ? 0 : Double(lastDeltaBytes)
            inFlight.append((keyframe, candidate, charge))
            credit -= charge
            dropsInRow = 0
            return keyframe
        }

        private mutating func drop() -> Bool? {
            dropsInRow += 1
            return nil
        }

        /// The encoder took the frame admitted last.
        mutating func sent(keyframe: Bool, at time: Double) {
            if keyframe {
                keyframePending = false
                lastKeyframeTime = time
            }
        }

        /// The encoder refused the frame admitted last; a keyframe request stays pending.
        mutating func failed() {
            guard let last = inFlight.popLast() else { return }
            credit += last.charged
        }

        /// The oldest frame in flight came out (no reordering, so output is in input order).
        mutating func landed(time: Double, bytes: Int, keyframe: Bool) {
            let entry = inFlight.isEmpty ? nil : inFlight.removeFirst()
            window.append((time, bytes, keyframe))
            windowBytes += bytes
            largestSeen = max(largestSeen ?? 0, bytes)
            if keyframe {
                lastKeyframeBytes = bytes
                // The encoder may add one of its own; the schedule counts from it.
                lastKeyframeTime = max(lastKeyframeTime ?? time, time)
            } else {
                // The credit was charged an estimate; settle it at the real size.
                credit += (entry?.charged ?? 0) - Double(bytes)
                lastDeltaBytes = bytes
            }
        }

        /// The oldest frame in flight failed in the encoder.
        mutating func lost() {
            guard !inFlight.isEmpty else { return }
            credit += inFlight.removeFirst().charged
        }
    }

    /// State the session's callback shares with the encoder. The callback holds this, never the
    /// encoder, so the last reference to the encoder can be dropped on any thread, including the
    /// VideoToolbox one.
    private final class Output {
        let lock = NSCondition()
        let onFrame: (Frame) -> Void
        var closed = false
        /// onFrame calls running now; invalidate waits for them.
        var delivering = 0
        var dropped = 0
        var rate: RateGuard
        init(onFrame: @escaping (Frame) -> Void, rate: RateGuard) {
            self.onFrame = onFrame
            self.rate = rate
        }

        /// Per thread: the outputs whose onFrame that thread is inside.
        static let callbackKey = "StreamVideoEncoder.callbacks"
        static var activeOnThisThread: NSCountedSet? {
            Thread.current.threadDictionary[callbackKey] as? NSCountedSet
        }
    }

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private let output: Output

    /// Frames not encoded: refused by the session, failed or empty in the callback, or dropped
    /// by the rate guard.
    var droppedFrames: Int {
        output.lock.lock()
        defer { output.lock.unlock() }
        return output.dropped
    }

    init?(width: Int, height: Int, bitrate: Int, frameRate: Int, onFrame: @escaping (Frame) -> Void) {
        guard let session = Self.makeSession(width: width, height: height) else { return nil }
        output = Output(onFrame: onFrame, rate: RateGuard(target: Double(bitrate) / 8, frameRate: frameRate))

        func set(_ key: CFString, _ value: Any) -> Bool {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef) == noErr
        }
        // The hardware encoder treats the data rate limit as a hint and overshoots on busy
        // pictures (measured), so the guard in `encode` is what holds the rate. The limit and the
        // key frame duration are still set, but a Mac that rejects them is not refused.
        let required = set(kVTCompressionPropertyKey_RealTime, true)
            && set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            && set(kVTCompressionPropertyKey_AllowFrameReordering, false)
            && set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 2 * frameRate)
            && set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
            && set(kVTCompressionPropertyKey_ExpectedFrameRate, frameRate)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2)
        // Bytes per second: 1.2x the average, over a 1 s window.
        _ = set(kVTCompressionPropertyKey_DataRateLimits, [Double(bitrate) * 1.2 / 8, 1.0])
        guard required, VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            return nil
        }
        self.session = session
    }

    deinit {
        // Never block here: the owner may be any thread.
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        guard let session else { return }
        output.lock.lock()
        output.closed = true
        output.lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    /// Returns false when the frame was not accepted (counted in `droppedFrames`). If the rate
    /// guard drops a frame sent with `forceKeyframe`, the request is kept for the next one.
    @discardableResult
    func encode(_ buffer: CVPixelBuffer, at time: CMTime, forceKeyframe: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return false }
        let output = self.output

        output.lock.lock()
        guard !output.closed, let keyframe = output.rate.admit(at: time.seconds, forceKeyframe: forceKeyframe) else {
            output.dropped += 1
            output.lock.unlock()
            return false
        }
        output.lock.unlock()

        let properties: CFDictionary? = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        // The handler runs on VideoToolbox's thread.
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sample in
            Self.handle(status: status, sample: sample, output: output)
        }
        output.lock.lock()
        defer { output.lock.unlock() }
        // The handler is not called when the call itself fails.
        guard status == noErr else {
            output.rate.failed()
            output.dropped += 1
            return false
        }
        output.rate.sent(keyframe: keyframe, at: time.seconds)
        return true
    }

    /// Completes pending frames, then tears the session down. No output follows its return.
    /// Called from an encoder's onFrame, it drops pending frames instead and finishes the
    /// teardown on another thread.
    func invalidate() {
        let active = Output.activeOnThisThread
        if let active, active.count > 0 {
            // Neither the encoder's lock (a thread in `encode` may hold it while VideoToolbox
            // waits for this thread) nor the session may be waited on from here. Stop output now;
            // wait for onFrame calls on other threads unless this is one of ours.
            output.lock.lock()
            output.closed = true
            if !active.contains(output) {
                while output.delivering > 0 { output.lock.wait() }
            }
            output.lock.unlock()
            DispatchQueue.global(qos: .utility).async { self.invalidate() }
            return
        }
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
        output.lock.lock()
        output.closed = true
        while output.delivering > 0 { output.lock.wait() }
        output.lock.unlock()
        if let session { VTCompressionSessionInvalidate(session) }
    }

    private static func handle(status: OSStatus, sample: CMSampleBuffer?, output: Output) {
        let frame = status == noErr ? sample.flatMap(makeFrame) : nil
        output.lock.lock()
        guard let frame else {
            output.rate.lost()
            output.dropped += 1
            output.lock.unlock()
            return
        }
        output.rate.landed(time: frame.time.seconds, bytes: frame.avcc.count, keyframe: frame.keyframe)
        if output.closed { output.lock.unlock(); return }
        output.delivering += 1
        // Not held across onFrame: it may take a while or call back into the encoder.
        output.lock.unlock()

        let dictionary = Thread.current.threadDictionary
        let active = dictionary[Output.callbackKey] as? NSCountedSet ?? NSCountedSet()
        dictionary[Output.callbackKey] = active
        active.add(output)
        output.onFrame(frame)
        active.remove(output)

        output.lock.lock()
        output.delivering -= 1
        if output.delivering == 0 { output.lock.broadcast() }
        output.lock.unlock()
    }

    private static func makeFrame(_ sample: CMSampleBuffer) -> Frame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer else { return nil }
        let avcc = Data(bytes: pointer, count: length)

        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }

        var sps: Data?
        var pps: Data?
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            sps = Self.parameterSet(format, index: 0)
            pps = Self.parameterSet(format, index: 1)
        }
        return Frame(avcc: avcc, keyframe: keyframe, time: CMSampleBufferGetPresentationTimeStamp(sample), sps: sps, pps: pps)
    }

    private static func parameterSet(_ format: CMFormatDescription, index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
        return Data(bytes: pointer, count: size)
    }
}
