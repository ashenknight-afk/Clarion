import CoreVideo
import Foundation
import Metal

private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool { abs(a - b) <= tolerance }

private typealias Color = (b: UInt8, g: UInt8, r: UInt8)
private let red: Color = (0, 0, 255), green: Color = (0, 255, 0), blue: Color = (255, 0, 0), black: Color = (0, 0, 0)

private func makeBuffer(_ width: Int, _ height: Int, _ color: (Int, Int) -> Color) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                                       kCVPixelBufferMetalCompatibilityKey: true]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    let result = buffer!
    CVPixelBufferLockBaseAddress(result, [])
    let base = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(result)
    for y in 0..<height {
        for x in 0..<width {
            let c = color(x, y)
            let p = base + y * stride + x * 4
            p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(result, [])
    return result
}

private func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> Color {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return (p[0], p[1], p[2])
}

private func isColor(_ c: Color, _ expected: Color) -> Bool {
    abs(Int(c.b) - Int(expected.b)) <= 3 && abs(Int(c.g) - Int(expected.g)) <= 3 && abs(Int(c.r) - Int(expected.r)) <= 3
}

private func compose(_ compositor: StreamCompositor, game: CVPixelBuffer?, camera: CVPixelBuffer? = nil,
                     layout: CameraLayout? = nil, canvas: (Int, Int) = (1920, 1080)) throws -> CVPixelBuffer {
    let done = DispatchSemaphore(value: 0)
    var result: CVPixelBuffer?
    compositor.compose(game: game, camera: camera, layout: layout, canvas: canvas) { result = $0; done.signal() }
    try expect(done.wait(timeout: .now() + 5) == .success, "compose timed out")
    guard let result else { throw CheckFailure(description: "compose returned nil") }
    return result
}

func compositorChecks() {
    check("gameRect fits and centres") {
        let wide = StreamCompositor.gameRect(source: CGSize(width: 3024, height: 1700), canvas: CGSize(width: 1920, height: 1080))
        try expect(wide.minX == 0 && near(wide.width, 1920), "wide \(wide)")
        try expect(abs(wide.height - 1079.4) < 1, "height \(wide.height)")
        try expect(near(wide.midY, 540), "centred \(wide)")
        let four3 = StreamCompositor.gameRect(source: CGSize(width: 1440, height: 1080), canvas: CGSize(width: 1920, height: 1080))
        try expect(near(four3.width, 1440) && near(four3.minX, 240) && near(four3.height, 1080), "4:3 \(four3)")
    }
    check("cameraRect margins") {
        let rect = StreamCompositor.cameraRect(canvas: CGSize(width: 1920, height: 1080), aspect: 16.0 / 9.0,
                                               layout: CameraLayout(corner: .bottomRight, size: .medium))
        try expect(near(rect.width, 384) && near(rect.height, 216), "size \(rect)")
        try expect(near(1920 - rect.maxX, 38.4) && near(1080 - rect.maxY, 38.4), "margins \(rect)")
        let topLeft = StreamCompositor.cameraRect(canvas: CGSize(width: 1920, height: 1080), aspect: 16.0 / 9.0,
                                                  layout: CameraLayout(corner: .topLeft, size: .small))
        try expect(near(topLeft.minX, 38.4) && near(topLeft.minY, 38.4) && near(topLeft.width, 288), "top left \(topLeft)")
    }
    check("quality choice") {
        try expect(StreamQuality.choose(wanted: .p2160, frameHeight: 1700, hardware: { _, _ in true }) == .p1440, "1700")
        try expect(StreamQuality.choose(wanted: .p2160, frameHeight: 900, hardware: { _, _ in true }) == .p1080, "900")
        try expect(StreamQuality.choose(wanted: .p2160, frameHeight: 2160, hardware: { _, h in h < 1440 }) == .p1080, "refuse 1440+")
        try expect(StreamQuality.choose(wanted: .p2160, frameHeight: 2160, hardware: { _, _ in false }) == nil, "refuse all")
        try expect(StreamQuality.choose(wanted: .p1440, frameHeight: 2160, hardware: { _, _ in true }) == .p1440, "wanted caps")
    }

    guard let device = MTLCreateSystemDefaultDevice() else {
        print("skip: compositor GPU checks (no Metal device)")
        return
    }
    guard let source = try? String(contentsOfFile: repoRoot + "/Clarion/Stream.metal", encoding: .utf8),
          let library = try? device.makeLibrary(source: source, options: nil),
          let compositor = try? StreamCompositor(device: device, library: library) else {
        check("compositor setup") { throw CheckFailure(description: "could not build compositor from Stream.metal") }
        return
    }

    check("scales a wide game to the canvas") {
        let out = try compose(compositor, game: makeBuffer(3024, 1700) { _, _ in red })
        try expect(CVPixelBufferGetWidth(out) == 1920 && CVPixelBufferGetHeight(out) == 1080, "size")
        try expect(isColor(pixel(out, 960, 540), red), "centre \(pixel(out, 960, 540))")
    }
    check("4:3 game is pillarboxed") {
        let out = try compose(compositor, game: makeBuffer(1440, 1080) { _, _ in red })
        try expect(isColor(pixel(out, 10, 540), black), "left \(pixel(out, 10, 540))")
        try expect(isColor(pixel(out, 960, 540), red), "centre \(pixel(out, 960, 540))")
    }
    check("picture is not flipped") {
        let out = try compose(compositor, game: makeBuffer(1920, 1080) { _, y in y < 540 ? red : blue })
        try expect(isColor(pixel(out, 960, 100), red), "top \(pixel(out, 960, 100))")
        try expect(isColor(pixel(out, 960, 1000), blue), "bottom \(pixel(out, 960, 1000))")
    }
    check("camera drawn in its corner") {
        let layout = CameraLayout(corner: .bottomRight, size: .medium)
        let out = try compose(compositor, game: makeBuffer(1920, 1080) { _, _ in red },
                              camera: makeBuffer(1280, 720) { _, _ in green }, layout: layout)
        let rect = StreamCompositor.cameraRect(canvas: CGSize(width: 1920, height: 1080), aspect: 16.0 / 9.0, layout: layout)
        try expect(isColor(pixel(out, Int(rect.midX), Int(rect.midY)), green), "camera centre")
        try expect(isColor(pixel(out, 100, 100), red), "game")
        // The rounded corner leaves the game showing at the rect's very corner.
        try expect(isColor(pixel(out, Int(rect.minX) + 1, Int(rect.minY) + 1), red), "corner \(pixel(out, Int(rect.minX) + 1, Int(rect.minY) + 1))")
    }
    check("camera is cropped, not stretched") {
        // 4:3 camera, left and right thirds blue, middle green: the 16:9 crop keeps rows, so only the centre shows.
        let camera = makeBuffer(800, 600) { x, _ in x < 100 || x >= 700 ? blue : green }
        let layout = CameraLayout(corner: .topLeft, size: .large)
        let out = try compose(compositor, game: makeBuffer(1920, 1080) { _, _ in red }, camera: camera, layout: layout)
        let rect = StreamCompositor.cameraRect(canvas: CGSize(width: 1920, height: 1080), aspect: 16.0 / 9.0, layout: layout)
        try expect(isColor(pixel(out, Int(rect.minX) + 20, Int(rect.midY)), blue), "left edge keeps the full width")
        try expect(isColor(pixel(out, Int(rect.midX), Int(rect.midY)), green), "centre")
    }
    check("game size changes between calls") {
        let first = try compose(compositor, game: makeBuffer(3024, 1700) { _, _ in red })
        let second = try compose(compositor, game: makeBuffer(2560, 1440) { _, _ in red })
        try expect(CVPixelBufferGetWidth(first) == 1920 && CVPixelBufferGetHeight(first) == 1080, "first")
        try expect(CVPixelBufferGetWidth(second) == 1920 && CVPixelBufferGetHeight(second) == 1080, "second")
    }
    check("no game gives a black canvas") {
        let out = try compose(compositor, game: nil)
        try expect(isColor(pixel(out, 960, 540), black) && isColor(pixel(out, 5, 5), black), "black")
    }
    check("bad canvas is rejected") {
        let done = DispatchSemaphore(value: 0)
        var result: CVPixelBuffer?
        compositor.compose(game: nil, camera: nil, layout: nil, canvas: (0, 1080)) { result = $0; done.signal() }
        try expect(done.wait(timeout: .now() + 5) == .success, "timed out")
        try expect(result == nil, "expected nil")
    }
}
