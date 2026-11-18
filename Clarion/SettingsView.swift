import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: Recorder
    @ObservedObject var capture: CaptureManager
    @ObservedObject var windowCapture: WindowCaptureManager
    @ObservedObject var audio: AudioPassthrough
    @ObservedObject var displays: DisplayManager
    let supportsMetalFX: Bool
    let supportsFrameGeneration: Bool
    let onClose: () -> Void

    private var selectedFormat: CaptureFormatOption? {
        capture.formats.first { $0.id == settings.formatID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clarion").font(.title2.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Form {
                Section("Source") {
                    Picker("Source", selection: $settings.source) {
                        ForEach(VideoSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if settings.source == .captureCard {
                    captureSection
                } else {
                    windowSection
                }
                outputSection
                enhancementSection
                if settings.source == .captureCard {
                    audioSection
                }
                recordingSection
                Section("Overlay & testing") {
                    Toggle("Show stats overlay", isOn: $settings.showOverlay)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Latency test", isOn: $settings.latencyTest)
                        Text("A square in the video's corner turns white whenever the centre of the picture is bright. Film the screen in slow motion to time it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                shortcutsSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var captureSection: some View {
        Section("Capture") {
            if capture.state == .denied {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clarion needs camera access to read your capture card.")
                    Button("Open Privacy Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                }
            }

            Picker("Device", selection: $settings.deviceID) {
                if settings.deviceID == nil || !capture.devices.contains(where: { $0.id == settings.deviceID }) {
                    Text(settings.deviceID != nil ? "Saved device (unplugged)"
                         : capture.devices.isEmpty ? "None connected" : "Automatic")
                        .tag(settings.deviceID)
                }
                ForEach(capture.devices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }

            Picker("Format", selection: $settings.formatID) {
                if selectedFormat == nil {
                    Text("Default").tag(settings.formatID)
                }
                ForEach(capture.formats) { format in
                    Text(format.label).tag(Optional(format.id))
                }
            }

            Picker("Frame rate", selection: $settings.frameRate) {
                Text("Highest").tag(0.0)
                ForEach(selectedFormat?.frameRates ?? [], id: \.self) { fps in
                    Text("\(formatFPS(fps)) fps").tag(fps)
                }
            }

            if selectedFormat?.isCompressed == true {
                Label("MJPEG is decoded before display and adds latency. Use 420v or YUY2 if your card offers it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.yellow)
            }

            if !capture.activeSummary.isEmpty {
                Text(capture.activeSummary).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// "app\u{1}title"; nil = automatic.
    private var windowChoice: Binding<String?> {
        Binding(
            get: { settings.windowApp.map { "\($0)\u{1}\(settings.windowTitle ?? "")" } },
            set: { value in
                let parts = value?.components(separatedBy: "\u{1}")
                settings.windowTitle = parts?.dropFirst().first
                settings.windowApp = parts?.first
            }
        )
    }

    private var windowSection: some View {
        Section("Window") {
            if windowCapture.state == .denied {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clarion needs Screen Recording access to read another app's window. Turn it on, then relaunch Clarion.")
                    Button("Open Screen Recording Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }

            HStack {
                Picker("Window", selection: windowChoice) {
                    Text("Automatic (find Remote Play)").tag(String?.none)
                    if let app = settings.windowApp,
                       !windowCapture.windows.contains(where: { $0.appName == app && $0.title == (settings.windowTitle ?? "") }) {
                        Text("\(app) (not open)").tag(windowChoice.wrappedValue)
                    }
                    ForEach(windowCapture.windows) { window in
                        Text(window.label).tag(Optional("\(window.appName)\u{1}\(window.title)"))
                    }
                }
                Button {
                    windowCapture.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh the window list")
            }

            Toggle("Hide the window's title bar", isOn: $settings.windowHideTitleBar)

            Text("Keep the streaming app open; it can sit behind Clarion. Window capture adds about one frame of latency on top of the stream's own delay.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !windowCapture.activeSummary.isEmpty {
                Text(windowCapture.activeSummary).font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { windowCapture.refresh() }
    }

    private var outputSection: some View {
        Section("Output") {
            Picker("Display", selection: $settings.displayID) {
                Text("Automatic").tag(UInt32(0))
                ForEach(displays.displays) { display in
                    Text(display.summary).tag(display.id)
                }
            }

            Picker("Scaling", selection: $settings.scalingMode) {
                ForEach(ScalingMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("V-Sync", isOn: $settings.displaySyncEnabled)
                Text("Off gives the lowest latency but can tear.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var enhancementSection: some View {
        Section("Enhancement") {
            Toggle("Upscaling", isOn: $settings.upscalingEnabled)
            if settings.upscalingEnabled {
                if supportsMetalFX {
                    Picker("Method", selection: $settings.upscaler) {
                        ForEach(Upscaler.Kind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    LabeledContent("Method", value: "Lanczos")
                }
                Text("Runs only when the screen is bigger than the capture, e.g. 1080p on a 4K TV. Adds GPU time, not frames of delay.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Toggle("Sharpening", isOn: $settings.sharpeningEnabled)
            if settings.sharpeningEnabled {
                LabeledContent("Strength") {
                    HStack {
                        Slider(value: settings.source == .window ? $settings.windowSharpness : $settings.sharpness, in: 0...1)
                        Text(String(format: "%.0f%%", settings.effectiveSharpness * 100))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            if supportsFrameGeneration {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Frame generation (30 → 60 fps)", isOn: $settings.frameGenerationEnabled)
                    if settings.frameGenerationEnabled {
                        Picker("Generated frames", selection: $settings.frameGenerationFast) {
                            Text("Fast (720p)").tag(true)
                            Text("Full (1080p)").tag(false)
                        }
                        .pickerStyle(.segmented)
                        Text("Fast makes the in-between frames at 720p: about 10 ms less delay. Real frames, and anything that holds still such as the HUD, stay full resolution.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if settings.source == .window {
                            Toggle("Steadier motion", isOn: $settings.frameGenerationSteady)
                            Text("Streams deliver some frames late. On: one frame waits ready to cover for them, which can add about 17 ms on a 60 Hz screen. Off: lowest delay, with a few more small hitches a second.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Label("Adds latency: each real frame waits half a frame (about 17 ms at 30 fps) plus processing, so an in-between frame can be shown first. Best for exploring; turn it off for tight timing.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(settings.frameGenerationEnabled ? .yellow : .secondary)
                }
            }
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Toggle("Play capture card audio", isOn: $settings.audioEnabled)
            if settings.audioEnabled {
                Picker("Input", selection: $settings.audioDeviceID) {
                    Text("Match capture device").tag(String?.none)
                    ForEach(audio.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                LabeledContent("Volume") {
                    Slider(value: $settings.audioVolume, in: 0...1)
                }
                switch audio.state {
                case .noMatch:
                    Text("Couldn't find the capture card's audio automatically. Choose it above.")
                        .font(.callout).foregroundStyle(.yellow)
                case .denied:
                    Button("Open Microphone Privacy Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                case .failed(let reason):
                    Text(reason).font(.callout).foregroundStyle(.yellow)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var recordingSection: some View {
        Section("Screenshots & recording") {
            HStack {
                Button("Take screenshot") { recorder.takeScreenshot() }
                Spacer()
                Button(recorder.isRecording ? "Stop recording" : "Start recording") { recorder.toggleRecording() }
            }
            Toggle("Include the stats", isOn: $settings.recordStats)
            Text("Saves the enhanced picture. Screenshots go to Pictures → Clarion, recordings (with the game's sound) to Movies → Clarion.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Show recordings in Finder") {
                if let folder = Recorder.folder(.moviesDirectory) { NSWorkspace.shared.open(folder) }
            }
        }
    }

    private var shortcutsSection: some View {
        Section("Shortcuts") {
            shortcut("Tab  or  ⌘,", "Show / hide settings")
            shortcut("O", "Stats overlay")
            shortcut("M", "Cycle Fit / Fill / Stretch")
            shortcut("V", "V-Sync on / off")
            shortcut("U", "Upscaling on / off")
            shortcut("S", "Sharpening on / off")
            if supportsFrameGeneration {
                shortcut("F", "Frame generation on / off")
            }
            shortcut("A", "Audio on / off")
            shortcut("P", "Take a screenshot")
            shortcut("R", "Start / stop recording")
            shortcut("L", "Latency test on / off")
            shortcut("⌘Q", "Quit")
        }
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        HStack {
            Text(keys).font(.system(.body, design: .monospaced))
            Spacer()
            Text(action).foregroundStyle(.secondary)
        }
    }
}
