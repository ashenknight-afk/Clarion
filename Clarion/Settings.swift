import Foundation
import Combine

enum ScalingMode: String, CaseIterable, Identifiable {
    case fit, fill, stretch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        }
    }

    var next: ScalingMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum VideoSource: String, CaseIterable, Identifiable {
    case captureCard, window

    var id: String { rawValue }

    var label: String {
        switch self {
        case .captureCard: return "Capture card"
        case .window: return "Remote Play app"
        }
    }
}

/// User preferences, persisted to UserDefaults on every change. Main thread only.
final class AppSettings: ObservableObject {
    private enum Key {
        static let source = "source"
        static let windowApp = "window.app"
        static let windowTitle = "window.title"
        static let windowHideTitleBar = "window.hideTitleBar"
        static let windowSharpness = "window.sharpness"
        static let deviceID = "capture.deviceID"
        static let formatID = "capture.formatID"
        static let frameRate = "capture.frameRate"
        static let displayID = "output.displayID"
        static let scalingMode = "output.scalingMode"
        static let displaySync = "output.displaySync"
        static let showOverlay = "overlay.visible"
        static let upscaling = "enhance.upscaling"
        static let upscaler = "enhance.upscaler"
        static let sharpening = "enhance.sharpening"
        static let sharpness = "enhance.sharpness"
        static let frameGeneration = "enhance.frameGeneration"
        static let frameGenerationFast = "enhance.frameGenerationFast"
        static let frameGenerationSteady = "enhance.frameGenerationSteady"
        static let recordStats = "recording.includeStats"
        static let audioEnabled = "audio.enabled"
        static let audioDeviceID = "audio.deviceID"
        static let audioVolume = "audio.volume"
        static func streamEnabled(_ site: StreamSite) -> String { "stream.\(site.rawValue).enabled" }
        static func streamServer(_ site: StreamSite) -> String { "stream.\(site.rawValue).server" }
        static func streamBitrate(_ site: StreamSite) -> String { "stream.\(site.rawValue).bitrate" }
        static let streamYouTubeQuality = "stream.youtube.quality"
        static let streamGameVolume = "stream.gameVolume"
    }

    private let defaults: UserDefaults

    @Published var source: VideoSource { didSet { defaults.set(source.rawValue, forKey: Key.source) } }
    /// nil = automatic (first window of a known streaming app).
    @Published var windowApp: String? { didSet { defaults.set(windowApp, forKey: Key.windowApp) } }
    @Published var windowTitle: String? { didSet { defaults.set(windowTitle, forKey: Key.windowTitle) } }
    @Published var windowHideTitleBar: Bool { didSet { defaults.set(windowHideTitleBar, forKey: Key.windowHideTitleBar) } }
    /// Streams are compressed, so they get gentler sharpening than a capture card by default.
    @Published var windowSharpness: Double { didSet { defaults.set(windowSharpness, forKey: Key.windowSharpness) } }

    /// `nil` = pick the first external capture device.
    @Published var deviceID: String? { didSet { defaults.set(deviceID, forKey: Key.deviceID) } }
    /// `nil` = 1920×1080, 420v preferred.
    @Published var formatID: String? { didSet { defaults.set(formatID, forKey: Key.formatID) } }
    /// 0 = highest rate the format supports.
    @Published var frameRate: Double { didSet { defaults.set(frameRate, forKey: Key.frameRate) } }
    /// 0 = automatic (first external display, else the main display).
    @Published var displayID: UInt32 { didSet { defaults.set(Int(displayID), forKey: Key.displayID) } }
    @Published var scalingMode: ScalingMode { didSet { defaults.set(scalingMode.rawValue, forKey: Key.scalingMode) } }
    @Published var displaySyncEnabled: Bool { didSet { defaults.set(displaySyncEnabled, forKey: Key.displaySync) } }
    @Published var showOverlay: Bool { didSet { defaults.set(showOverlay, forKey: Key.showOverlay) } }
    @Published var upscalingEnabled: Bool { didSet { defaults.set(upscalingEnabled, forKey: Key.upscaling) } }
    /// Preferred method; MetalFX silently falls back to Lanczos where unsupported.
    @Published var upscaler: Upscaler.Kind { didSet { defaults.set(upscaler.rawValue, forKey: Key.upscaler) } }
    @Published var sharpeningEnabled: Bool { didSet { defaults.set(sharpeningEnabled, forKey: Key.sharpening) } }
    /// 0…1.
    @Published var sharpness: Double { didSet { defaults.set(sharpness, forKey: Key.sharpness) } }
    /// Off by default: it adds latency.
    @Published var frameGenerationEnabled: Bool { didSet { defaults.set(frameGenerationEnabled, forKey: Key.frameGeneration) } }
    /// In-between frames at 720p (less delay) instead of 1080p.
    @Published var frameGenerationFast: Bool { didSet { defaults.set(frameGenerationFast, forKey: Key.frameGenerationFast) } }
    /// Trade up to a refresh of delay for steadier motion on a stream that delivers frames unevenly.
    @Published var frameGenerationSteady: Bool { didSet { defaults.set(frameGenerationSteady, forKey: Key.frameGenerationSteady) } }
    /// Draw the stats panel into screenshots and recordings.
    @Published var recordStats: Bool { didSet { defaults.set(recordStats, forKey: Key.recordStats) } }
    @Published var audioEnabled: Bool { didSet { defaults.set(audioEnabled, forKey: Key.audioEnabled) } }
    /// nil = the audio of the active capture device.
    @Published var audioDeviceID: String? { didSet { defaults.set(audioDeviceID, forKey: Key.audioDeviceID) } }
    /// 0…1.
    @Published var audioVolume: Double { didSet { defaults.set(audioVolume, forKey: Key.audioVolume) } }
    /// Stream keys are not settings: they live in the keychain (`StreamKeychain`).
    @Published var streamEnabled: [StreamSite: Bool] {
        didSet { StreamSite.allCases.forEach { defaults.set(streamEnabled[$0] ?? false, forKey: Key.streamEnabled($0)) } }
    }
    /// Empty = the site's default server.
    @Published var streamServer: [StreamSite: String] {
        didSet { StreamSite.allCases.forEach { defaults.set(streamServer[$0] ?? "", forKey: Key.streamServer($0)) } }
    }
    /// Bits per second; 0 = the site's default for the canvas.
    @Published var streamBitrate: [StreamSite: Int] {
        didSet { StreamSite.allCases.forEach { defaults.set(streamBitrate[$0] ?? 0, forKey: Key.streamBitrate($0)) } }
    }
    @Published var streamYouTubeQuality: StreamQuality {
        didSet { defaults.set(streamYouTubeQuality.rawValue, forKey: Key.streamYouTubeQuality) }
    }
    /// 0…1.
    @Published var streamGameVolume: Double { didSet { defaults.set(streamGameVolume, forKey: Key.streamGameVolume) } }
    /// A measuring aid, so it always starts off.
    @Published var latencyTest = false

    var renderConfig: RenderConfig {
        RenderConfig(scalingMode: scalingMode, upscaling: upscalingEnabled, upscaler: upscaler,
                     sharpening: sharpeningEnabled, sharpness: Float(effectiveSharpness),
                     frameGeneration: frameGenerationEnabled, fastFrameGeneration: frameGenerationFast,
                     steadyFrameGeneration: frameGenerationSteady,
                     latencyTest: latencyTest)
    }

    var effectiveSharpness: Double { source == .window ? windowSharpness : sharpness }

    var windowSelection: WindowSelection {
        WindowSelection(appName: windowApp, title: windowTitle, hideTitleBar: windowHideTitleBar)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Before settings version 2 the automatically chosen device was saved too (often the built-in
        // camera); forget it once so "Automatic" can find the capture card.
        if defaults.integer(forKey: "settingsVersion") < 2 {
            defaults.removeObject(forKey: Key.deviceID)
            defaults.set(2, forKey: "settingsVersion")
        }
        source = VideoSource(rawValue: defaults.string(forKey: Key.source) ?? "") ?? .captureCard
        windowApp = defaults.string(forKey: Key.windowApp)
        windowTitle = defaults.string(forKey: Key.windowTitle)
        windowHideTitleBar = defaults.object(forKey: Key.windowHideTitleBar) as? Bool ?? true
        windowSharpness = defaults.object(forKey: Key.windowSharpness) as? Double ?? 0.25
        deviceID = defaults.string(forKey: Key.deviceID)
        formatID = defaults.string(forKey: Key.formatID)
        frameRate = defaults.double(forKey: Key.frameRate)
        displayID = UInt32(clamping: defaults.integer(forKey: Key.displayID))
        scalingMode = ScalingMode(rawValue: defaults.string(forKey: Key.scalingMode) ?? "") ?? .fit
        displaySyncEnabled = defaults.object(forKey: Key.displaySync) as? Bool ?? true
        showOverlay = defaults.object(forKey: Key.showOverlay) as? Bool ?? true
        upscalingEnabled = defaults.object(forKey: Key.upscaling) as? Bool ?? true
        upscaler = Upscaler.Kind(rawValue: defaults.string(forKey: Key.upscaler) ?? "") ?? .metalFX
        sharpeningEnabled = defaults.object(forKey: Key.sharpening) as? Bool ?? true
        sharpness = defaults.object(forKey: Key.sharpness) as? Double ?? 0.5
        frameGenerationEnabled = defaults.bool(forKey: Key.frameGeneration)
        frameGenerationFast = defaults.object(forKey: Key.frameGenerationFast) as? Bool ?? true
        frameGenerationSteady = defaults.object(forKey: Key.frameGenerationSteady) as? Bool ?? true
        recordStats = defaults.bool(forKey: Key.recordStats)
        audioEnabled = defaults.object(forKey: Key.audioEnabled) as? Bool ?? true
        audioDeviceID = defaults.string(forKey: Key.audioDeviceID)
        audioVolume = defaults.object(forKey: Key.audioVolume) as? Double ?? 1
        streamEnabled = Dictionary(uniqueKeysWithValues: StreamSite.allCases.map { ($0, defaults.bool(forKey: Key.streamEnabled($0))) })
        streamServer = Dictionary(uniqueKeysWithValues: StreamSite.allCases.map { ($0, defaults.string(forKey: Key.streamServer($0)) ?? "") })
        streamBitrate = Dictionary(uniqueKeysWithValues: StreamSite.allCases.map { ($0, max(0, defaults.integer(forKey: Key.streamBitrate($0)))) })
        streamYouTubeQuality = StreamQuality(rawValue: defaults.object(forKey: Key.streamYouTubeQuality) as? Int ?? 1440) ?? .p1440
        streamGameVolume = defaults.object(forKey: Key.streamGameVolume) as? Double ?? 1
    }

    /// Reads the stream keys from the keychain: call it only when going live.
    func makeStreamConfig() -> StreamConfig {
        let sites = StreamSite.allCases.filter { streamEnabled[$0] == true }.map { site -> StreamSiteConfig in
            let server = (streamServer[site] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return StreamSiteConfig(site: site, server: server.isEmpty ? site.defaultServer : server,
                                    key: StreamKeychain.key(for: site) ?? "",
                                    quality: site == .youtube ? streamYouTubeQuality : .p1080,
                                    bitrate: streamBitrate[site] ?? 0)
        }
        return StreamConfig(sites: sites, gameVolume: Float(streamGameVolume), camera: nil, mic: nil)
    }
}
