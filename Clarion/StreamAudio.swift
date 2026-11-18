import AVFoundation
import CoreMedia

/// Any PCM sample buffer → 48 kHz stereo interleaved Float. One per source (it keeps resampler state).
final class PCMNormalizer {
    static let sampleRate = 48_000.0

    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMNormalizer.sampleRate,
                                             channels: 2, interleaved: true)!
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    /// Fraction of an output frame owed from earlier buffers.
    private var carry = 0.0

    func samples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        // More than two channels need a layout before AVAudioFormat accepts them.
        let layout = asbd.mChannelsPerFrame > 2
            ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame) : nil
        guard let format = AVAudioFormat(streamDescription: &asbd, channelLayout: layout) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return samples(from: buffer)
    }

    func samples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.frameLength > 0 else { return [] }
        let source = buffer.format.channelCount > 2 ? firstTwoChannels(of: buffer) : buffer
        guard let source else { return nil }
        if converterInput != source.format {
            converter = AVAudioConverter(from: source.format, to: outputFormat)
            converter?.primeMethod = .none
            converterInput = source.format
            carry = 0
        }
        guard let converter else { return nil }

        let ratio = Self.sampleRate / source.format.sampleRate
        // Ask for exactly what the input is worth: with spare room the converter stops at an internal
        // chunk size and keeps the rest back, which would delay this source by a variable amount.
        let wanted = Double(source.frameLength) * ratio + carry
        let capacity = AVAudioFrameCount(wanted)
        carry = wanted - Double(capacity)
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength) * 2))
    }

    /// The converter has no layout to fold more than two channels down with, so the first two are kept.
    private func firstTwoChannels(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 2, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        let layout = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let isFloat = buffer.format.commonFormat == .pcmFormatFloat32
        guard isFloat || buffer.format.commonFormat == .pcmFormatInt16 else { return nil }
        for ch in 0..<2 {
            for i in 0..<frames {
                // Interleaved data is one block; otherwise each channel has its own.
                let list = buffer.format.isInterleaved ? layout[0] : layout[ch]
                guard let raw = list.mData else { return nil }
                let index = buffer.format.isInterleaved ? i * channels + ch : i
                dst[ch][i] = isFloat
                    ? raw.assumingMemoryBound(to: Float.self)[index]
                    : Float(raw.assumingMemoryBound(to: Int16.self)[index]) / 32768
            }
        }
        return out
    }
}

/// Puts the sound sources on one 48 kHz timeline that starts at `startHostTime` and is cut into
/// 1024-frame blocks. Sources are placed by their host-clock time, so sound that arrives late
/// still lands where it belongs, and a source that is missing is silence.
struct StreamMixer {
    enum Source: CaseIterable { case game, mic }

    static let blockFrames = 1024
    static let delay = 0.1
    static let resyncAfter = 0.04

    private static let rate = 48_000.0
    /// Sound further ahead of the output than this is a bad timestamp, not something to hold on to.
    private static let farAhead = Int(2 * rate)
    /// Disagreement under this is left alone; above it (and under `resyncAfter`) it is eased out.
    private static let deadband = 48

    var volume: [Source: Float] = [.game: 1, .mic: 1]
    var micMuted = false

    private struct Track {
        /// Interleaved stereo. Its first frame sits at `endFrame - queue.count / 2`.
        var queue: [Float] = []
        /// Output frame (from the start) where this source's timeline ends. Nil until it first pushes.
        var endFrame: Int?
    }

    private let startHostTime: Double
    private var tracks: [Source: Track] = [:]
    /// Frames already handed out.
    private var emitted = 0

    init(startHostTime: Double) {
        self.startHostTime = startHostTime
    }

    /// How much sound the source has queued past what was already emitted.
    func queuedSeconds(_ source: Source) -> Double {
        guard let track = tracks[source], let end = track.endFrame else { return 0 }
        return Double(max(0, end - emitted)) / Self.rate
    }

    mutating func push(_ source: Source, samples: [Float], hostTime: Double) {
        let frames = samples.count / 2
        guard frames > 0 else { return }
        var track = tracks[source] ?? Track()
        let target = Int(((hostTime - startHostTime) * Self.rate).rounded())
        var data = samples[0..<(frames * 2)]

        if target > emitted + Self.farAhead { return }

        if let end = track.endFrame {
            let diff = target - end
            if abs(diff) > Int(Self.resyncAfter * Self.rate) {
                if diff > 0 {
                    // Later than the timeline: the gap is silence. An empty queue needs no padding,
                    // pull treats the space before the data as silence.
                    if !track.queue.isEmpty { track.queue.append(contentsOf: repeatElement(0, count: diff * 2)) }
                    track.endFrame = target
                } else {
                    // Earlier: the overlap was already queued.
                    data = data.dropFirst(min(-diff, frames) * 2)
                }
            } else if abs(diff) > Self.deadband {
                // Clock drift or jitter: ease it out a little per push, so a source that is slightly
                // fast or slow neither piles up nor needs a realignment click every few seconds.
                let step = min(abs(diff), max(1, frames / 400))
                if diff > 0 {
                    // Hold the last frame, not silence.
                    let l = track.queue.count >= 2 ? track.queue[track.queue.count - 2] : 0
                    let r = track.queue.count >= 2 ? track.queue[track.queue.count - 1] : 0
                    for _ in 0..<step { track.queue.append(l); track.queue.append(r) }
                    track.endFrame = end + step
                } else {
                    data = data.dropFirst(step * 2)
                }
            }
        } else {
            track.endFrame = target
        }

        let end = track.endFrame ?? target
        track.queue.append(contentsOf: data)
        track.endFrame = end + data.count / 2
        // The part before what was already emitted is too late to use.
        let head = track.endFrame! - track.queue.count / 2
        if head < emitted { track.queue.removeFirst(min(emitted - head, track.queue.count / 2) * 2) }
        tracks[source] = track
    }

    mutating func remove(_ source: Source) {
        tracks[source] = nil
    }

    mutating func pull(now: Double) -> [(samples: [Float], hostTime: Double)] {
        var blocks: [(samples: [Float], hostTime: Double)] = []
        let block = Self.blockFrames
        while startHostTime + Double(emitted + block) / Self.rate <= now - Self.delay {
            blocks.append((mixBlock(), startHostTime + Double(emitted) / Self.rate))
            emitted += block
        }
        return blocks
    }

    private mutating func mixBlock() -> [Float] {
        let block = Self.blockFrames
        var mix = [Float](repeating: 0, count: block * 2)
        for source in Source.allCases {
            guard var track = tracks[source], let end = track.endFrame else { continue }
            var gain = volume[source] ?? 1
            if source == .mic && micMuted { gain = 0 }
            var head = end - track.queue.count / 2
            // Whatever is older than this block can no longer be played.
            if head < emitted {
                let drop = min(emitted - head, track.queue.count / 2)
                track.queue.removeFirst(drop * 2)
                head += drop
            }
            let skip = max(0, min(head - emitted, block))
            let take = min(block - skip, track.queue.count / 2)
            if take > 0 {
                if gain != 0 {
                    for i in 0..<(take * 2) { mix[skip * 2 + i] += track.queue[i] * gain }
                }
                track.queue.removeFirst(take * 2)
            }
            tracks[source] = track
        }
        for i in 0..<mix.count { mix[i] = max(-1, min(1, mix[i])) }
        return mix
    }
}

/// AAC-LC, 48 kHz stereo. One 1024-frame block in, one raw AAC frame (no ADTS header) out.
/// The matching AudioSpecificConfig is `11 90`.
final class StreamAudioEncoder {
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioCompressedBuffer

    init?(bitrate: Int = 160_000) {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true),
              let aac = AVAudioFormat(settings: [
                  AVFormatIDKey: kAudioFormatMPEG4AAC,
                  AVSampleRateKey: 48_000,
                  AVNumberOfChannelsKey: 2,
              ]),
              let converter = AVAudioConverter(from: pcm, to: aac),
              let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(StreamMixer.blockFrames))
        else { return nil }
        converter.bitRate = bitrate
        self.converter = converter
        self.input = input
        output = AVAudioCompressedBuffer(format: aac, packetCapacity: 4,
                                         maximumPacketSize: max(converter.maximumOutputPacketSize, 1024))
    }

    func encode(_ block: [Float]) -> Data? {
        guard block.count == StreamMixer.blockFrames * 2, let dst = input.floatChannelData else { return nil }
        block.withUnsafeBufferPointer { src in
            dst[0].update(from: src.baseAddress!, count: block.count)
        }
        input.frameLength = AVAudioFrameCount(StreamMixer.blockFrames)
        output.byteLength = 0
        output.packetCount = 0
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return self.input
        }
        guard status != .error, error == nil, output.packetCount > 0, output.byteLength > 0,
              let descriptions = output.packetDescriptions else { return nil }
        let first = descriptions[0]
        let bytes = output.data.advanced(by: Int(first.mStartOffset)).assumingMemoryBound(to: UInt8.self)
        return Data(bytes: bytes, count: Int(first.mDataByteSize))
    }
}
