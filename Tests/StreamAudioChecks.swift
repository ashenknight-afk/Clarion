import AVFoundation
import CoreMedia
import Foundation

private let rate = 48_000.0

private func constant(_ value: Float, seconds: Double) -> [Float] {
    [Float](repeating: value, count: Int(seconds * rate) * 2)
}

private func flat(_ blocks: [(samples: [Float], hostTime: Double)]) -> [Float] {
    blocks.flatMap { $0.samples }
}

private func int16MonoBuffer(frames: Int, sampleRate: Double) -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
        mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                         magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
          let format else { return nil }
    let pcm: [Int16] = (0..<frames).map { Int16(10_000 * sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
    let bytes = pcm.count * 2
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                             customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                             blockBufferOut: &block) == noErr, let block else { return nil }
    guard pcm.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                                              dataLength: bytes) }) == noErr else { return nil }
    var sample: CMSampleBuffer?
    guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
        presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
    return sample
}

func streamAudioChecks() {
    let start = 1000.0

    check("mixer with no pushes emits contiguous silence from the start") {
        var mixer = StreamMixer(startHostTime: start)
        let blocks = mixer.pull(now: start + 1)
        try expect(blocks.count > 30, "blocks \(blocks.count)")
        try expect(abs(blocks[0].hostTime - start) < 1e-9, "first at \(blocks[0].hostTime)")
        for (n, block) in blocks.enumerated() {
            try expect(block.samples.count == 2048, "size")
            try expect(abs(block.hostTime - (start + Double(n) * 1024 / rate)) < 1e-9, "time of block \(n)")
        }
        try expect(flat(blocks).allSatisfy { $0 == 0 }, "not silent")
    }

    check("mixer applies volume and mute") {
        var mixer = StreamMixer(startHostTime: start)
        mixer.volume[.mic] = 0.5
        mixer.push(.game, samples: constant(0.25, seconds: 1), hostTime: start)
        mixer.push(.mic, samples: constant(0.5, seconds: 1), hostTime: start)
        let mixed = flat(mixer.pull(now: start + 0.6))
        try expect(mixed.count > 20_000 && mixed.allSatisfy { abs($0 - 0.5) < 1e-6 }, "volume mix")

        var muted = StreamMixer(startHostTime: start)
        muted.micMuted = true
        muted.push(.game, samples: constant(0.25, seconds: 1), hostTime: start)
        muted.push(.mic, samples: constant(0.5, seconds: 1), hostTime: start)
        let quiet = flat(muted.pull(now: start + 0.6))
        try expect(quiet.allSatisfy { abs($0 - 0.25) < 1e-6 }, "muted mix")
    }

    check("mixer clamps the sum") {
        var mixer = StreamMixer(startHostTime: start)
        mixer.push(.game, samples: constant(0.8, seconds: 1), hostTime: start)
        mixer.push(.mic, samples: constant(0.8, seconds: 1), hostTime: start)
        let mixed = flat(mixer.pull(now: start + 0.6))
        try expect(!mixed.isEmpty && mixed.allSatisfy { $0 == 1 }, "not clamped")
    }

    check("a late push leaves silence then the sound") {
        var mixer = StreamMixer(startHostTime: start)
        mixer.push(.game, samples: constant(0.5, seconds: 0.1), hostTime: start)
        // Timeline ends at 0.1 s; the next push starts at 0.3 s.
        mixer.push(.game, samples: constant(0.5, seconds: 0.1), hostTime: start + 0.3)
        let mixed = flat(mixer.pull(now: start + 0.5))
        func frame(_ t: Double) -> Float { mixed[Int(t * rate) * 2] }
        try expect(frame(0.05) == 0.5, "first part")
        try expect(frame(0.12) == 0 && frame(0.28) == 0, "gap not silent")
        try expect(frame(0.35) == 0.5, "second part")
    }

    check("jittered timestamps stay contiguous") {
        var mixer = StreamMixer(startHostTime: start)
        var rng = SystemRandomNumberGenerator()
        let chunk = 0.02
        var blocks: [(samples: [Float], hostTime: Double)] = []
        for i in 0..<100 {
            let jitter = Double.random(in: -0.01...0.01, using: &rng)
            let t = start + 0.1 + Double(i) * chunk
            mixer.push(.game, samples: constant(0.5, seconds: chunk), hostTime: t + jitter)
            blocks += mixer.pull(now: t + chunk + 0.02)
        }
        let mixed = flat(blocks)
        let from = Int(0.15 * rate) * 2, to = Int(1.95 * rate) * 2
        try expect(mixed[from..<to].allSatisfy { $0 != 0 }, "zeros inside at \(mixed[from..<to].firstIndex { $0 == 0 }.map { Double($0 / 2) / rate } ?? -1) of \(mixed.count)")
    }

    check("a fast source never builds up a queue") {
        var mixer = StreamMixer(startHostTime: start)
        let chunk = 0.02
        let frames = Int(chunk * rate)
        let samples = constant(0.3, seconds: chunk)
        let drift = 1.001
        var worst = 0.0, firstSecondWorst = 0.0, lastSecondWorst = 0.0
        var pulled = 0
        var t = 0.0 // source's own clock
        var zeros = 0
        while t < 60 {
            // Its sound is stamped by the host clock but made 0.1% faster than it.
            let host = start + 0.05 + t / drift
            let now = host + chunk + 0.04
            mixer.push(.game, samples: samples, hostTime: host)
            for block in mixer.pull(now: now) {
                pulled += 1
                if t > 1, block.samples.contains(0) { zeros += 1 }
            }
            let q = mixer.queuedSeconds(.game)
            worst = max(worst, q)
            if t < 5 { firstSecondWorst = max(firstSecondWorst, q) }
            if t > 55 { lastSecondWorst = max(lastSecondWorst, q) }
            t += Double(frames) / rate
        }
        try expect(worst <= 0.1, "queue reached \(worst) s")
        try expect(lastSecondWorst <= firstSecondWorst + 0.005, "grew from \(firstSecondWorst) to \(lastSecondWorst)")
        try expect(zeros <= 2, "\(zeros) blocks with gaps")
        try expect(pulled > 2000, "pulled \(pulled)")
    }

    check("a slow source never starves into repeated gaps") {
        var mixer = StreamMixer(startHostTime: start)
        let chunk = 0.02
        let samples = constant(0.3, seconds: chunk)
        var zeros = 0, t = 0.0
        while t < 60 {
            let host = start + 0.05 + t / 0.999
            mixer.push(.game, samples: samples, hostTime: host)
            for block in mixer.pull(now: host + chunk + 0.04) where t > 1 && block.samples.contains(0) { zeros += 1 }
            t += chunk
        }
        try expect(zeros <= 2, "\(zeros) blocks with gaps")
    }

    check("nothing newer than now minus the delay is returned") {
        var mixer = StreamMixer(startHostTime: start)
        let now = start + 2.345
        let blocks = mixer.pull(now: now)
        let last = blocks.last!
        try expect(last.hostTime + 1024 / rate <= now - StreamMixer.delay + 1e-9, "block too new")
        try expect(mixer.pull(now: now).isEmpty, "emitted twice")
    }

    check("a removed source goes silent and holds nothing back") {
        var mixer = StreamMixer(startHostTime: start)
        mixer.push(.game, samples: constant(0.5, seconds: 1), hostTime: start)
        mixer.remove(.game)
        try expect(mixer.queuedSeconds(.game) == 0, "queue kept")
        try expect(flat(mixer.pull(now: start + 0.6)).allSatisfy { $0 == 0 }, "not silent")
    }

    check("sound from before the emitted position is dropped") {
        var mixer = StreamMixer(startHostTime: start)
        _ = mixer.pull(now: start + 1.1) // emitted up to ~1 s
        mixer.push(.game, samples: constant(0.5, seconds: 0.5), hostTime: start + 0.5)
        let blocks = mixer.pull(now: start + 2)
        let mixed = flat(blocks)
        let sinceFirst = blocks[0].hostTime
        let audible = mixed.firstIndex { $0 != 0 }
        // Only the part that reaches past the emitted position (about 1 s) may sound.
        try expect(audible == nil || Double(audible! / 2) / rate + sinceFirst < start + 1.01, "late part mixed in")
    }

    check("normalizer turns 44.1 kHz mono Int16 into 48 kHz stereo") {
        guard let buffer = int16MonoBuffer(frames: 4410, sampleRate: 44_100) else { throw CheckFailure(description: "no buffer") }
        let out = PCMNormalizer().samples(from: buffer)
        try expect(out != nil, "nil")
        try expect(abs(out!.count - 9600) <= 64, "count \(out!.count)")
        var same = true
        for i in 0..<(out!.count / 2) where out![i * 2] != out![i * 2 + 1] { same = false }
        try expect(same, "left != right")
        try expect(out!.contains { abs($0) > 0.1 }, "silent")
    }

    check("normalizer keeps the first two of many channels, non-interleaved Float") {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 6)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for ch in 0..<6 { for i in 0..<480 { buffer.floatChannelData![ch][i] = Float(ch + 1) / 10 } }
        let out = PCMNormalizer().samples(from: buffer)
        try expect(out != nil && abs(out!.count - 960) <= 64, "count \(out?.count ?? -1)")
        let mid = out!.count / 2
        try expect(abs(out![mid] - 0.1) < 0.01 && abs(out![mid + 1] - 0.2) < 0.01, "channels \(out![mid]) \(out![mid + 1])")
    }

    check("normalizer keeps the first two channels of interleaved Int16") {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, interleaved: true, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        let p = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Int16.self)
        for i in 0..<480 { p[i * 3] = 3277; p[i * 3 + 1] = -3277; p[i * 3 + 2] = 9999 }
        let out = PCMNormalizer().samples(from: buffer)
        try expect(out != nil && abs(out!.count - 960) <= 64, "count \(out?.count ?? -1)")
        let mid = out!.count / 2
        try expect(abs(out![mid] - 0.1) < 0.01 && abs(out![mid + 1] + 0.1) < 0.01, "channels \(out![mid]) \(out![mid + 1])")
    }

    check("encoder makes AAC frames from a tone") {
        guard let encoder = StreamAudioEncoder() else { throw CheckFailure(description: "no encoder") }
        try expect(encoder.encode([Float](repeating: 0, count: 100)) == nil, "wrong size accepted")
        var frames = 0
        for n in 0..<100 {
            var block = [Float](repeating: 0, count: 2048)
            for i in 0..<1024 {
                let v = Float(0.3 * sin(2 * Double.pi * 440 * Double(n * 1024 + i) / rate))
                block[i * 2] = v
                block[i * 2 + 1] = v
            }
            if let data = encoder.encode(block), !data.isEmpty { frames += 1 }
        }
        try expect(frames >= 98, "frames \(frames)")
    }
}
