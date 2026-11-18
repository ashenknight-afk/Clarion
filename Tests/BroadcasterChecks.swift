import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal

/// Runs the main run loop, where the broadcaster publishes its state, until `condition` holds.
@discardableResult
private func spin(timeout: TimeInterval, until condition: () -> Bool = { false }) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < end else { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    return true
}

/// A grey picture with a white square whose place depends on `index`: calm enough that the rate guard keeps every frame.
private func squareFrame(width: Int, height: Int, index: Int) -> CVPixelBuffer? {
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                                       kCVPixelBufferMetalCompatibilityKey: true]
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let side = height / 8, left = (index * width / 10) % (width - side), top = height / 3
    for y in 0..<height {
        let row = base + y * stride
        memset(row, 90, width * 4)
        if y >= top && y < top + side { memset(row + left * 4, 255, side * 4) }
    }
    return buffer
}

/// 10 ms of a 440 Hz tone, 48 kHz stereo Float, starting at sample `start`.
private func toneBuffer(start: Int, frames: Int = 480) -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
        mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                         magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
          let format else { return nil }
    var pcm = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let value = Float(0.3 * sin(2 * Double.pi * 440 * Double(start + i) / 48_000))
        pcm[i * 2] = value
        pcm[i * 2 + 1] = value
    }
    let bytes = pcm.count * 4
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                             customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                             blockBufferOut: &block) == noErr, let block,
          pcm.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                              offsetIntoDestination: 0, dataLength: bytes) }) == noErr
    else { return nil }
    var sample: CMSampleBuffer?
    guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
        presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
    return sample
}

/// Feeds a broadcaster frames at 60 Hz and sound in 10 ms buffers, both at real time, on its own queue.
private final class Feeder {
    private let queue = DispatchQueue(label: "BroadcasterChecks.feeder", qos: .userInitiated)
    private let broadcaster: Broadcaster
    private let small: [CVPixelBuffer]
    private let large: [CVPixelBuffer]
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private var soundStart = 0.0
    private var soundBuffers = 0
    /// queue only
    private var useLarge = false

    init?(broadcaster: Broadcaster) {
        self.broadcaster = broadcaster
        let small = (0..<10).compactMap { squareFrame(width: 1280, height: 720, index: $0) }
        let large = (0..<10).compactMap { squareFrame(width: 2560, height: 1440, index: $0) }
        guard small.count == 10, large.count == 10 else { return nil }
        self.small = small
        self.large = large
    }

    func start() {
        queue.sync {
            soundStart = CACurrentMediaTime()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func switchToLarge() { queue.sync { useLarge = true } }

    func stop() { queue.sync { timer?.cancel(); timer = nil } }

    private func tick() {
        let now = CACurrentMediaTime()
        let frames = useLarge ? large : small
        broadcaster.handle(frame: frames[frameIndex % frames.count], at: now)
        frameIndex += 1
        // Sound in 10 ms buffers stamped on one continuous timeline, as a capture device delivers it.
        while soundStart + Double(soundBuffers + 1) * 0.01 <= now {
            let time = soundStart + Double(soundBuffers) * 0.01
            if let sound = toneBuffer(start: soundBuffers * 480) {
                broadcaster.handle(gameAudio: sound, at: CMTime(seconds: time, preferredTimescale: 1_000_000_000))
            }
            soundBuffers += 1
        }
    }
}

private final class Locked<Value> {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

private func oneSite(_ site: StreamSite = .twitch, quality: StreamQuality = .p1080, port: UInt16, key: String) -> StreamConfig {
    StreamConfig(sites: [StreamSiteConfig(site: site, server: "rtmp://127.0.0.1:\(port)/live", key: key,
                                          quality: quality, bitrate: 0)],
                 gameVolume: 1, camera: nil, mic: nil)
}

private func bytes(_ message: RTMPMessage, _ count: Int = 2) -> [UInt8] { Array(message.payload.prefix(count)) }

func broadcasterChecks() {
    check("drawingTarget copies a shared frame, keeps an unshared one") {
        guard let frame = squareFrame(width: 640, height: 360, index: 3) else { throw CheckFailure(description: "no frame") }
        var pool: CVPixelBufferPool?
        let same = Recorder.drawingTarget(for: frame, shared: false, pool: &pool)
        try expect(same === frame, "shared: false gave another buffer")
        guard let copy = Recorder.drawingTarget(for: frame, shared: true, pool: &pool) else {
            throw CheckFailure(description: "no copy")
        }
        try expect(copy !== frame, "shared: true gave the same buffer")
        try expect(CVPixelBufferGetWidth(copy) == 640 && CVPixelBufferGetHeight(copy) == 360, "copy size")
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(copy, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(copy, .readOnly)
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        let a = CVPixelBufferGetBaseAddress(frame)!, b = CVPixelBufferGetBaseAddress(copy)!
        let strideA = CVPixelBufferGetBytesPerRow(frame), strideB = CVPixelBufferGetBytesPerRow(copy)
        for y in 0..<360 {
            try expect(memcmp(a + y * strideA, b + y * strideB, 640 * 4) == 0, "row \(y) differs")
        }
    }

    check("stream keys go in and out of the keychain") {
        try expect(StreamKeychain.service.hasSuffix(".checks"), "harness service \(StreamKeychain.service)")
        let cleared = StreamKeychain.set(nil, for: .youtube)
        if StreamKeychain.needsInteraction(cleared) {
            print("skip: keychain checks (the keychain wants interaction)")
            return
        }
        // The item is this run's own (the account carries the process id); never leave it behind.
        defer { StreamKeychain.set(nil, for: .youtube) }
        let added = StreamKeychain.set("check-key-123", for: .youtube)
        if StreamKeychain.needsInteraction(added) {
            print("skip: keychain checks (the keychain wants interaction)")
            return
        }
        try expect(added == errSecSuccess, "add status \(added)")
        try expect(StreamKeychain.key(for: .youtube) == "check-key-123", "read back")
        try expect(StreamKeychain.hasKey(for: .youtube), "saved key not seen")
        try expect(StreamKeychain.set("", for: .youtube) == errSecSuccess, "empty deletes")
        try expect(StreamKeychain.key(for: .youtube) == nil, "read after delete")
        try expect(!StreamKeychain.hasKey(for: .youtube), "deleted key still seen")
        StreamKeychain.set("other", for: .youtube)
        StreamKeychain.set(nil, for: .youtube)
        try expect(StreamKeychain.key(for: .youtube) == nil, "read after nil")
    }

    guard let device = MTLCreateSystemDefaultDevice() else {
        print("skip: broadcaster checks (no Metal device)")
        return
    }
    guard StreamVideoEncoder.hardwareAvailable(width: 1920, height: 1080) else {
        print("skip: broadcaster checks (no hardware H.264 encoder)")
        return
    }
    guard let source = try? String(contentsOfFile: repoRoot + "/Clarion/Stream.metal", encoding: .utf8),
          let library = try? device.makeLibrary(source: source, options: nil) else {
        check("broadcaster setup") { throw CheckFailure(description: "could not build Stream.metal") }
        return
    }

    check("go live without a key or a site says what is missing") {
        let broadcaster = Broadcaster(device: device, library: library)
        broadcaster.goLive(oneSite(port: 1935, key: "  "))
        spin(timeout: 0.1)
        try expect(!broadcaster.isLive, "went live without a key")
        try expect(broadcaster.notice == "Add a Twitch stream key in Settings", "notice \(broadcaster.notice ?? "nil")")
        broadcaster.goLive(StreamConfig(sites: [], gameVolume: 1, camera: nil, mic: nil))
        spin(timeout: 0.1)
        try expect(!broadcaster.isLive, "went live with no site")
        try expect(broadcaster.notice == "Turn on Twitch or YouTube in Settings", "notice \(broadcaster.notice ?? "nil")")
    }

    check("streams picture and sound to one site") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        let wants = Locked<[Bool]>([])
        broadcaster.onWantsFrames = { wanted in wants.update { $0.append(wanted) } }
        let canvases = Locked<Set<String>>([])
        broadcaster.onCanvas = { buffer in
            canvases.update { $0.insert("\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))") }
        }
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }

        // YouTube asks for 1440p; a 720p picture gets 1080p, and a 1440p picture later must not change it.
        broadcaster.goLive(oneSite(.youtube, quality: .p1440, port: server.port, key: " abc \n"))
        try expect(spin(timeout: 5) { broadcaster.states[.youtube] == .live },
                   "not live: \(String(describing: broadcaster.states[.youtube])) \(broadcaster.notice ?? "")")
        try expect(broadcaster.info[.youtube]?.hasPrefix("9.0 Mbps · 1080p") == true, "info \(broadcaster.info[.youtube] ?? "nil")")
        spin(timeout: 1.5)
        feeder.switchToLarge()
        spin(timeout: 1.5)
        try expect(broadcaster.states[.youtube] == .live, "after the size change: \(String(describing: broadcaster.states[.youtube]))")
        var ended = false, endedAgain = false
        broadcaster.end { ended = true }
        // A second end (quitting while ending) waits for the same close.
        broadcaster.end { endedAgain = true }
        try expect(!endedAgain, "second end completed before the first")
        try expect(spin(timeout: 5) { ended && endedAgain }, "end didn't complete: \(ended) \(endedAgain)")
        try expect(!broadcaster.isLive && broadcaster.states[.youtube] == .off, "still live after end")
        try expect(wants.value.first == true && wants.value.last == false, "frame wants \(wants.value)")
        spin(timeout: 0.3)

        try expect(server.publishedKey == "abc", "published key \(server.publishedKey ?? "nil")")
        let media = server.received.filter { [8, 9, 18].contains($0.type) }
        try expect(media.count >= 4, "only \(media.count) media messages")
        try expect(media[0].type == 18, "first is not metadata: type \(media[0].type)")
        try expect(media[1].type == 9 && bytes(media[1]) == [0x17, 0x00], "second is not the AVC header: \(bytes(media[1]))")
        try expect(media[2].type == 8 && bytes(media[2]) == [0xAF, 0x00], "third is not the AAC header: \(bytes(media[2]))")
        try expect(media[3].type == 9 && bytes(media[3]) == [0x17, 0x01], "fourth is not a keyframe: \(bytes(media[3]))")

        let video = media.filter { $0.type == 9 }
        let audio = media.filter { $0.type == 8 }
        try expect((170...190).contains(video.count), "\(video.count) video messages")
        try expect((135...146).contains(audio.count), "\(audio.count) audio messages")
        try expect(video.first?.timestamp == 0, "first video timestamp \(video.first?.timestamp ?? 0)")
        try expect(zip(video, video.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }, "video timestamps go backwards")
        try expect(zip(audio, audio.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }, "audio timestamps go backwards")
        let lastVideo = Int(video.last?.timestamp ?? 0), lastAudio = Int(audio.last?.timestamp ?? 0)
        try expect(abs(lastVideo - lastAudio) < 200, "last video \(lastVideo) ms, last audio \(lastAudio) ms")

        try expect(canvases.value == ["1920x1080"], "canvases \(canvases.value)")
        try expect(media.filter { $0.type == 18 }.count == 1, "metadata sent again")
        try expect(video.filter { bytes($0) == [0x17, 0x00] }.count == 1, "sequence header sent again")
    }

    check("no picture for 5 s does not go live") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        let started = Date()
        broadcaster.goLive(oneSite(port: server.port, key: "abc"))
        try expect(broadcaster.isLive, "not starting")
        try expect(spin(timeout: 7) { broadcaster.notice != nil }, "no notice")
        try expect(Date().timeIntervalSince(started) > 4.8, "gave up after \(Date().timeIntervalSince(started)) s")
        try expect(broadcaster.notice == "No picture to stream", "notice \(broadcaster.notice ?? "nil")")
        try expect(!broadcaster.isLive, "live without a picture")
        try expect(server.publishedKey == nil, "published without a picture")
    }
}
