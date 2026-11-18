import Combine
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore

enum StreamSite: String, CaseIterable, Identifiable {
    case twitch, youtube

    var id: String { rawValue }

    var label: String {
        switch self {
        case .twitch: return "Twitch"
        case .youtube: return "YouTube"
        }
    }

    var defaultServer: String {
        switch self {
        case .twitch: return "rtmps://live.twitch.tv/app"
        case .youtube: return "rtmps://a.rtmps.youtube.com/live2"
        }
    }

    /// Bits per second.
    func defaultBitrate(_ quality: StreamQuality) -> Int {
        switch (self, quality) {
        case (.twitch, _): return 6_000_000
        case (.youtube, .p1080): return 9_000_000
        case (.youtube, .p1440): return 18_000_000
        case (.youtube, .p2160): return 35_000_000
        }
    }
}

struct StreamSiteConfig {
    let site: StreamSite
    let server: String
    let key: String
    /// The canvas asked for; a smaller one is used when the picture or the hardware can't fill it.
    let quality: StreamQuality
    /// Bits per second; 0 = the site's default for the canvas in use.
    let bitrate: Int
}

struct StreamConfig {
    var sites: [StreamSiteConfig]
    var gameVolume: Float
    var camera: (deviceID: String?, layout: CameraLayout)?
    var mic: (deviceID: String?, volume: Float, removeGameSound: Bool)?
}

/// Sends the finished picture and the game's sound to the streaming sites. Like `Recorder`: control
/// on the main thread, work on its own queue. A 60 Hz timer there takes the newest frame (or the
/// last one again), composes it per canvas, encodes it per site and sends it with the mixed sound.
final class Broadcaster: ObservableObject {
    enum SiteState: Equatable { case off, connecting, live, reconnecting(Int), failed(String) }

    static let pictureTimeout = 5.0

    @Published private(set) var states: [StreamSite: SiteState] = Dictionary(uniqueKeysWithValues: StreamSite.allCases.map { ($0, .off) })
    @Published private(set) var startedAt: Date?
    @Published private(set) var notice: String?
    /// Bitrate and canvas per site, shown next to its state.
    @Published private(set) var info: [StreamSite: String] = [:]

    var isLive: Bool {
        states.values.contains { state in
            switch state {
            case .connecting, .live, .reconnecting: return true
            case .off, .failed: return false
            }
        }
    }

    /// Main thread: turn the renderer's frame hand-over on or off.
    var onWantsFrames: ((Bool) -> Void)?
    /// Main thread: ask the source for its sound while live.
    var onWantsAudio: ((Bool) -> Void)?
    /// Queue: the camera's newest picture, drawn in a corner when the config has a camera.
    var cameraFrame: (() -> CVPixelBuffer?)?
    /// Checks only: each composed canvas before it is encoded, on the queue.
    var onCanvas: ((CVPixelBuffer) -> Void)?
    /// Checks only: each mixed sound block (interleaved stereo, host time of its start) before it is encoded, on the queue.
    var onSoundBlock: (([Float], Double) -> Void)?

    private let queue = DispatchQueue(label: "clarion.broadcaster", qos: .userInitiated)
    private let compositor: StreamCompositor?

    // main thread only
    private var ending = false

    // lock
    private let lock = NSLock()
    private var accepting = false
    private var newest: CVPixelBuffer?

    // queue only
    private var running = false
    private var session = 0
    private var config: StreamConfig?
    private var timer: DispatchSourceTimer?
    private var pictureDeadline = 0.0
    private var lastFrame: CVPixelBuffer?
    private var sitesStarted = false
    private var sites: [StreamSite: BroadcastSite] = [:]
    private var composing: Set<StreamQuality> = []
    private var mixer: StreamMixer?
    private let gameNormalizer = PCMNormalizer()
    private var audioEncoder: StreamAudioEncoder?

    init(device: MTLDevice, library: MTLLibrary) {
        compositor = try? StreamCompositor(device: device, library: library)
    }

    // MARK: - Main thread

    func goLive(_ config: StreamConfig) {
        guard !isLive, !ending else { return }
        guard !config.sites.isEmpty else { return show("Turn on Twitch or YouTube in Settings") }
        if let missing = config.sites.first(where: { $0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return show("Add a \(missing.site.label) stream key in Settings")
        }
        guard compositor != nil else { return show("Streaming isn't available on this Mac") }
        notice = nil
        info = [:]
        startedAt = nil
        for site in config.sites { states[site.site] = .connecting }
        onWantsFrames?(true)
        onWantsAudio?(true)
        lock.lock()
        accepting = true
        newest = nil
        lock.unlock()
        queue.async { self.start(config) }
    }

    /// Ends every site cleanly. `completion` runs on the main thread once all are closed.
    func end(completion: (() -> Void)? = nil) {
        guard isLive, !ending else {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        ending = true
        stopTakingInput()
        queue.async {
            let open = self.stopSession()
            let group = DispatchGroup()
            for site in open {
                group.enter()
                site.close { group.leave() }
            }
            group.notify(queue: .main) {
                self.ending = false
                for site in StreamSite.allCases where self.states[site] != .off { self.states[site] = .off }
                self.startedAt = nil
                completion?()
            }
        }
    }

    // MARK: - Any thread

    /// The finished picture from the renderer. Only stored: the timer takes it.
    func handle(frame: CVPixelBuffer, at hostTime: CFTimeInterval) {
        lock.lock()
        if accepting { newest = frame }
        lock.unlock()
    }

    /// Game sound. `hostTime` is given when the buffer's own timestamp is on another clock.
    func handle(gameAudio sampleBuffer: CMSampleBuffer, at hostTime: CMTime? = nil) {
        guard isAccepting else { return }
        queue.async {
            guard self.running, self.mixer != nil,
                  let samples = self.gameNormalizer.samples(from: sampleBuffer), !samples.isEmpty else { return }
            let time = (hostTime ?? CMSampleBufferGetPresentationTimeStamp(sampleBuffer)).seconds
            self.mixer?.push(.game, samples: samples, hostTime: time)
        }
    }

    /// Microphone sound, already 48 kHz interleaved stereo, starting at `hostTime` on the host clock.
    func handle(micSamples: [Float], hostTime: Double) {
        guard isAccepting else { return }
        queue.async {
            guard self.running else { return }
            self.mixer?.push(.mic, samples: micSamples, hostTime: hostTime)
        }
    }

    private var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting
    }

    // MARK: - Main thread helpers

    private func show(_ text: String) {
        notice = text
    }

    /// Releases the frame sink and the sound at once; the stream itself closes after.
    private func stopTakingInput() {
        lock.lock()
        accepting = false
        newest = nil
        lock.unlock()
        onWantsFrames?(false)
        onWantsAudio?(false)
    }

    private func publish(_ state: SiteState, for site: StreamSite) {
        DispatchQueue.main.async {
            self.states[site] = state
            if state == .live, self.startedAt == nil { self.startedAt = Date() }
        }
    }

    // MARK: - Queue

    private func start(_ config: StreamConfig) {
        session += 1
        self.config = config
        running = true
        let now = CACurrentMediaTime()
        pictureDeadline = now + Self.pictureTimeout
        lastFrame = nil
        sitesStarted = false
        composing = []
        var mixer = StreamMixer(startHostTime: now)
        mixer.volume[.game] = config.gameVolume
        if let mic = config.mic { mixer.volume[.mic] = mic.volume }
        self.mixer = mixer
        audioEncoder = StreamAudioEncoder()
        guard audioEncoder != nil else { return giveUp("Couldn't start the sound encoder") }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Stops the timer and forgets the session. Returns the sites still open, for the caller to close.
    private func stopSession() -> [BroadcastSite] {
        guard running else { return [] }
        running = false
        timer?.cancel()
        timer = nil
        // The sound still held back by the mixer's delay belongs to the pictures already sent.
        pullSound(now: CACurrentMediaTime() + StreamMixer.delay)
        let open = Array(sites.values)
        sites = [:]
        config = nil
        lastFrame = nil
        mixer = nil
        audioEncoder = nil
        composing = []
        return open
    }

    /// Ends the session from the queue, with `text` (if any) as the notice. Sites already failed keep their state.
    private func giveUp(_ text: String?) {
        for site in stopSession() { site.close {} }
        DispatchQueue.main.async {
            if !self.ending { self.stopTakingInput() }
            if let text { self.notice = text }
            for (site, state) in self.states {
                switch state {
                case .connecting, .live, .reconnecting: self.states[site] = .off
                case .off, .failed: break
                }
            }
            if !self.isLive { self.startedAt = nil }
        }
    }

    private func tick() {
        guard running, let config else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        if let frame = newest {
            lastFrame = frame
            newest = nil
        }
        lock.unlock()

        if !sitesStarted {
            guard let frame = lastFrame else {
                if now >= pictureDeadline { giveUp("No picture to stream") }
                return
            }
            startSites(config, frameHeight: CVPixelBufferGetHeight(frame))
            guard running else { return }
        }

        pullSound(now: now)

        guard let frame = lastFrame, let compositor else { return }
        let session = self.session
        let canvases = Set(sites.values.map(\.quality))
        let camera = config.camera.flatMap { camera in cameraFrame?().map { ($0, camera.layout) } }
        for quality in canvases where !composing.contains(quality) {
            composing.insert(quality)
            compositor.compose(game: frame, camera: camera?.0, layout: camera?.1, canvas: quality.size) { [weak self] canvas in
                guard let self else { return }
                self.queue.async { self.composed(canvas, quality: quality, at: now, session: session) }
            }
        }
    }

    private func composed(_ canvas: CVPixelBuffer?, quality: StreamQuality, at time: Double, session: Int) {
        guard running, session == self.session else { return }
        composing.remove(quality)
        guard let canvas else { return }
        onCanvas?(canvas)
        for site in sites.values where site.quality == quality { site.encode(canvas, at: time) }
    }

    private func pullSound(now: Double) {
        guard let blocks = mixer?.pull(now: now), let audioEncoder else { return }
        for block in blocks {
            onSoundBlock?(block.samples, block.hostTime)
            // Encoded even before any site is live, so the encoder is primed by then.
            guard let aac = audioEncoder.encode(block.samples) else { continue }
            let body = FLV.aacFrame(aac)
            for site in sites.values { site.send(audio: body, hostTime: block.hostTime) }
        }
    }

    /// Picks each site's canvas for the first picture and starts its connection.
    private func startSites(_ config: StreamConfig, frameHeight: Int) {
        sitesStarted = true
        let session = self.session
        var infos: [StreamSite: String] = [:]
        var anyEncodable = false
        for siteConfig in config.sites {
            let site = siteConfig.site
            guard let quality = StreamQuality.choose(wanted: siteConfig.quality, frameHeight: frameHeight,
                                                     hardware: StreamVideoEncoder.hardwareAvailable) else {
                publish(.failed("This Mac can't encode the stream"), for: site)
                continue
            }
            anyEncodable = true
            let bitrate = siteConfig.bitrate > 0 ? siteConfig.bitrate : site.defaultBitrate(quality)
            let broadcastSite: BroadcastSite
            do {
                broadcastSite = try BroadcastSite(config: siteConfig, quality: quality, bitrate: bitrate, queue: queue)
            } catch {
                publish(.failed((error as? BroadcastSite.StartError)?.text ?? "Couldn't start"), for: site)
                continue
            }
            var text = String(format: "%.1f Mbps · %dp", Double(bitrate) / 1_000_000, quality.rawValue)
            if quality.rawValue < siteConfig.quality.rawValue {
                let asked = siteConfig.quality
                text += StreamVideoEncoder.hardwareAvailable(width: asked.size.width, height: asked.size.height)
                    ? " (the picture is smaller than \(asked.rawValue)p)" : " (this Mac can't encode \(asked.rawValue)p)"
            }
            infos[site] = text
            broadcastSite.onState = { [weak self] state in self?.siteChanged(site, state, session: session) }
            sites[site] = broadcastSite
            broadcastSite.start()
        }
        DispatchQueue.main.async { self.info = infos }
        if !anyEncodable { return giveUp("Streaming isn't available on this Mac") }
        if sites.isEmpty { giveUp(nil) }
    }

    private func siteChanged(_ site: StreamSite, _ state: RTMPConnection.State, session: Int) {
        guard running, session == self.session, sites[site] != nil else { return }
        switch state {
        case .publishing:
            publish(.live, for: site)
        case .failed(let text):
            sites[site] = nil
            publish(.failed(text), for: site)
            if sites.isEmpty { giveUp(nil) }
        case .closed:
            sites[site] = nil
            publish(.off, for: site)
            if sites.isEmpty { giveUp(nil) }
        case .connecting:
            break
        }
    }
}
