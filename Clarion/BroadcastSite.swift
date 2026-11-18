import CoreMedia
import CoreVideo
import Foundation

/// One site of a broadcast: its connection, its encoder and its stream clock. Queue only: every
/// method runs on the broadcaster's queue, which the connection uses too.
final class BroadcastSite {
    struct StartError: Error { let text: String }

    let config: StreamSiteConfig
    let quality: StreamQuality
    let bitrate: Int
    /// Reports the connection's state changes, on the queue.
    var onState: ((RTMPConnection.State) -> Void)?

    private let queue: DispatchQueue
    private let connection: RTMPConnection
    private var encoder: StreamVideoEncoder?
    private var publishing = false
    private var failed = false
    /// Host time of stream time zero: the first video frame sent on this connection. Sound uses it too.
    private var zero: Double?
    private var keyframeRequested = false
    private var sps: Data?
    private var pps: Data?
    private var lastVideo: UInt32 = 0
    private var lastAudio: UInt32 = 0

    init(config: StreamSiteConfig, quality: StreamQuality, bitrate: Int, queue: DispatchQueue) throws {
        guard let target = RTMPConnection.Target(server: config.server, key: config.key) else {
            throw StartError(text: "Check the server address in Settings")
        }
        self.config = config
        self.quality = quality
        self.bitrate = bitrate
        self.queue = queue
        connection = RTMPConnection(target: target, queue: queue)
        let size = quality.size
        // The encoder calls back on a VideoToolbox thread; everything here belongs to the queue.
        encoder = StreamVideoEncoder(width: size.width, height: size.height, bitrate: bitrate, frameRate: 60) { [weak self] frame in
            queue.async { self?.encoded(frame) }
        }
        guard encoder != nil else { throw StartError(text: "Couldn't start the video encoder") }
    }

    func start() {
        connection.onState = { [weak self] state in self?.connectionChanged(state) }
        connection.start()
    }

    /// A composed canvas for this site. Nothing is encoded until the server accepts the stream.
    func encode(_ canvas: CVPixelBuffer, at hostTime: Double) {
        guard publishing, !failed, let encoder else { return }
        // The first frame must be a keyframe. A forced keyframe the rate guard drops stays pending in the encoder.
        let force = !keyframeRequested
        keyframeRequested = true
        encoder.encode(canvas, at: CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000), forceKeyframe: force)
    }

    /// One AAC frame (FLV body) whose sound starts at `hostTime`.
    func send(audio: Data, hostTime: Double) {
        guard let zero, !failed, hostTime >= zero else { return }
        let timestamp = max(lastAudio, Self.milliseconds(hostTime - zero))
        lastAudio = timestamp
        connection.send(audio: audio, timestamp: timestamp)
    }

    /// Sends what the encoder still holds, then unpublishes. `completion` runs on the queue.
    func close(completion: @escaping () -> Void) {
        // Frames finished by `invalidate` are queued behind this block, so they go out before the close.
        encoder?.invalidate()
        encoder = nil
        queue.async { self.connection.close(completion: completion) }
    }

    private func connectionChanged(_ state: RTMPConnection.State) {
        switch state {
        case .publishing:
            publishing = true
        case .failed, .closed:
            publishing = false
            encoder?.invalidate()
            encoder = nil
        case .connecting:
            break
        }
        onState?(state)
    }

    private func fail(_ text: String) {
        guard !failed else { return }
        failed = true
        encoder?.invalidate()
        encoder = nil
        connection.close()
        onState?(.failed(text))
    }

    private func encoded(_ frame: StreamVideoEncoder.Frame) {
        guard publishing, !failed else { return }
        let time = frame.time.seconds
        guard time.isFinite else { return }
        if zero == nil {
            // Each connection starts with metadata, both sequence headers, then a keyframe at 0.
            guard frame.keyframe, let sps = frame.sps, let pps = frame.pps else { return }
            let header = FLV.avcSequenceHeader(sps: sps, pps: pps)
            guard !header.isEmpty else { return fail("The video encoder's output can't be streamed") }
            let size = quality.size
            connection.send(metadata: FLV.metadata(width: size.width, height: size.height, frameRate: 60,
                                                   videoKbps: bitrate / 1000, audioKbps: 160))
            connection.send(video: header, timestamp: 0, keyframe: true)
            connection.send(audio: FLV.aacSequenceHeader(), timestamp: 0)
            self.sps = sps
            self.pps = pps
            zero = time
        } else if frame.keyframe, let sps = frame.sps, let pps = frame.pps, sps != self.sps || pps != self.pps {
            // The parameter sets changed: the decoder needs the new ones before this keyframe.
            let header = FLV.avcSequenceHeader(sps: sps, pps: pps)
            guard !header.isEmpty else { return fail("The video encoder's output can't be streamed") }
            self.sps = sps
            self.pps = pps
            connection.send(video: header, timestamp: timestamp(for: time), keyframe: true)
        }
        let stamp = timestamp(for: time)
        lastVideo = stamp
        connection.send(video: FLV.avcFrame(frame.avcc, keyframe: frame.keyframe), timestamp: stamp, keyframe: frame.keyframe)
    }

    private func timestamp(for time: Double) -> UInt32 {
        guard let zero else { return 0 }
        return max(lastVideo, Self.milliseconds(time - zero))
    }

    private static func milliseconds(_ seconds: Double) -> UInt32 {
        UInt32(clamping: Int64((max(0, seconds) * 1000).rounded()))
    }
}
