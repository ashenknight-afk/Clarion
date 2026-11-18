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

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private let onFrame: (Frame) -> Void

    init?(width: Int, height: Int, bitrate: Int, frameRate: Int, onFrame: @escaping (Frame) -> Void) {
        guard let session = Self.makeSession(width: width, height: height) else { return nil }
        self.session = session
        self.onFrame = onFrame

        func set(_ key: CFString, _ value: Any) {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 2 * frameRate)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        // Bytes per second: 1.2x the average, over a 1 s window.
        set(kVTCompressionPropertyKey_DataRateLimits, [Double(bitrate) * 1.2 / 8, 1.0])
        set(kVTCompressionPropertyKey_ExpectedFrameRate, frameRate)
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            self.session = nil
            return nil
        }
    }

    deinit { invalidate() }

    func encode(_ buffer: CVPixelBuffer, at time: CMTime, forceKeyframe: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return }
        let properties: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        // The handler runs on VideoToolbox's thread. invalidate() drains it before clearing `session`.
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.emit(sample)
        }
    }

    /// Completes pending frames, then tears the session down. No output follows its return.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        self.session = nil
        VTCompressionSessionInvalidate(session)
    }

    private func emit(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer else { return }
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
        onFrame(Frame(avcc: avcc, keyframe: keyframe, time: CMSampleBufferGetPresentationTimeStamp(sample), sps: sps, pps: pps))
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
