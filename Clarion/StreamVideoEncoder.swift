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

    /// State the session's callback shares with the encoder. The callback holds this, never the
    /// encoder, so the last reference to the encoder can be dropped on any thread, including the
    /// VideoToolbox one.
    private final class Output {
        /// Recursive so `onFrame` may call back into the encoder.
        let lock = NSRecursiveLock()
        let onFrame: (Frame) -> Void
        var closed = false
        var dropped = 0
        var inFlight = 0
        /// Recent output as (presentation seconds, bytes), for the rate guard.
        var window: [(time: Double, bytes: Int)] = []
        var windowBytes = 0
        var largestKeyframe = 0
        var lastKeyframeTime: Double?
        /// A forced keyframe the guard dropped; the next admitted frame carries it.
        var keyframePending = false
        init(onFrame: @escaping (Frame) -> Void) { self.onFrame = onFrame }

        static let callbackKey = "StreamVideoEncoder.callback"
    }

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private let output: Output
    /// Bytes per second the guard lets through before it drops input (the target).
    private let guardBytesPerSecond: Double

    /// Frames not encoded: refused by the session, failed or empty in the callback, or dropped
    /// by the rate guard.
    var droppedFrames: Int {
        output.lock.lock()
        defer { output.lock.unlock() }
        return output.dropped
    }

    init?(width: Int, height: Int, bitrate: Int, frameRate: Int, onFrame: @escaping (Frame) -> Void) {
        guard let session = Self.makeSession(width: width, height: height) else { return nil }
        output = Output(onFrame: onFrame)
        guardBytesPerSecond = Double(bitrate) / 8

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
        close(then: session)
    }

    /// Returns false when the frame was not accepted (counted in `droppedFrames`). If the rate
    /// guard drops a frame sent with `forceKeyframe`, the request is kept for the next one.
    @discardableResult
    func encode(_ buffer: CVPixelBuffer, at time: CMTime, forceKeyframe: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return false }
        let seconds = time.seconds
        let output = self.output

        output.lock.lock()
        if output.closed { output.lock.unlock(); return false }
        // Input time went backwards: the old window says nothing about the new stretch.
        if let first = output.window.first, first.time > seconds {
            output.window.removeAll()
            output.windowBytes = 0
        }
        while let first = output.window.first, first.time <= seconds - 1 {
            output.windowBytes -= first.bytes
            output.window.removeFirst()
        }
        let keyframe = forceKeyframe || output.keyframePending
        // Cost of this frame and those still in the encoder: the largest recent frame each, and
        // for a keyframe (forced or due, the interval being 2 s) the largest keyframe seen.
        let largest = output.window.map(\.bytes).max() ?? 0
        let keyframeDue = output.lastKeyframeTime.map { seconds - $0 >= 1.9 } ?? false
        let candidate = keyframe || keyframeDue ? max(largest, output.largestKeyframe) : largest
        let projected = Double(output.windowBytes + output.inFlight * largest + candidate)
        // Until the first output shows what a frame costs, only a few may be in flight.
        if projected > guardBytesPerSecond || (output.window.isEmpty && output.inFlight >= 6) {
            output.dropped += 1
            if keyframe { output.keyframePending = true }
            output.lock.unlock()
            return false
        }
        output.keyframePending = false
        output.inFlight += 1
        output.lock.unlock()

        let properties: CFDictionary? = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        // The handler runs on VideoToolbox's thread.
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sample in
            Self.handle(status: status, sample: sample, output: output)
        }
        if status != noErr {
            // The handler is not called when the call itself fails.
            output.lock.lock()
            output.inFlight -= 1
            output.dropped += 1
            output.lock.unlock()
            return false
        }
        return true
    }

    /// Completes pending frames, then tears the session down. No output follows its return.
    func invalidate() {
        if Thread.current.threadDictionary[Output.callbackKey] != nil {
            // Called from onFrame. Neither the encoder's lock (a thread in `encode` may hold it
            // while waiting for this callback) nor the session may be waited on from here: stop
            // output now and finish the teardown on another thread.
            output.lock.lock()
            output.closed = true
            output.lock.unlock()
            DispatchQueue.global(qos: .utility).async { self.invalidate() }
            return
        }
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        output.lock.lock()
        output.closed = true
        output.lock.unlock()
        VTCompressionSessionInvalidate(session)
    }

    /// Stops output now and finishes the session off the calling thread.
    private func close(then session: VTCompressionSession) {
        output.lock.lock()
        output.closed = true
        output.lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    private static func handle(status: OSStatus, sample: CMSampleBuffer?, output: Output) {
        let frame = status == noErr ? sample.flatMap(makeFrame) : nil
        output.lock.lock()
        output.inFlight -= 1
        guard let frame else {
            output.dropped += 1
            output.lock.unlock()
            return
        }
        output.window.append((frame.time.seconds, frame.avcc.count))
        output.windowBytes += frame.avcc.count
        if frame.keyframe {
            output.largestKeyframe = max(output.largestKeyframe, frame.avcc.count)
            output.lastKeyframeTime = frame.time.seconds
        }
        let closed = output.closed
        // Not held across onFrame: it may take a while or call back into the encoder.
        output.lock.unlock()
        if closed { return }
        let marker = Thread.current.threadDictionary
        marker[Output.callbackKey] = true
        output.onFrame(frame)
        marker.removeObject(forKey: Output.callbackKey)
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
