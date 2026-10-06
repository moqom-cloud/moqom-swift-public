import CoreVideo
import Foundation
import MoqomCore
import MoqomKit

final class PatternSource: FrameSource, @unchecked Sendable {
    let captureFormat: CaptureFormat

    private let relay: FrameRelay

    private var pool: CVPixelBufferPool?

    private var drawn: PixelSize
    private var task: Task<Void, Never>?

    private var stopped = false

    private let previewStream: AsyncStream<VideoFrame>
    private let previewContinuation: AsyncStream<VideoFrame>.Continuation

    init(format: CaptureFormat, label: String) {
        captureFormat = format
        relay = FrameRelay(format: format, depth: 3)
        hue = Double(label.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 360 }) / 360
        drawn = format.size
        pool = Self.makePool(size: format.size)
        (previewStream, previewContinuation) = AsyncStream.makeStream(
            of: VideoFrame.self,
            bufferingPolicy: .bufferingNewest(2)
        )
    }

    private let hue: Double

    func frames() -> AsyncStream<VideoFrame> {
        start()
        return relay.frames()
    }

    func preview() -> AsyncStream<VideoFrame> {
        start()
        return previewStream
    }

    func stop() {
        stopped = true
        task?.cancel()
        task = nil
        relay.stop()
        previewContinuation.finish()
    }

    func resize(to size: PixelSize) {
        guard size.width > 0, size.height > 0, size != drawn else { return }
        drawn = size
        pool = Self.makePool(size: size)
    }

    func suspend() {
        task?.cancel()
        task = nil
    }

    func resume() {
        guard !stopped else { return }
        start()
    }

    private func start() {
        guard task == nil else { return }
        let interval = Duration.nanoseconds(
            Int(1_000_000_000 / max(1, captureFormat.frameRate))
        )
        task = Task { [weak self] in
            var index: UInt64 = 0
            while !Task.isCancelled {
                guard let self else { return }
                if let frame = render(index: index) {
                    relay.submit(frame)
                    previewContinuation.yield(frame)
                }
                index += 1
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func render(index: UInt64) -> VideoFrame? {
        guard let pool, let buffer = Self.buffer(from: pool) else { return nil }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let phase = Double(index % 120) / 120

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        let barX = Int(phase * Double(width))
        for y in 0 ..< height {
            let row = pixels + y * stride
            let vertical = Double(y) / Double(height)
            for x in 0 ..< width {
                let horizontal = Double(x) / Double(width)
                let (r, g, b) = Self.colour(
                    hue: (hue + horizontal * 0.25).truncatingRemainder(dividingBy: 1),
                    brightness: 0.35 + vertical * 0.4
                )
                let isBar = abs(x - barX) < 6
                let pixel = row + x * 4
                pixel[0] = isBar ? 255 : b
                pixel[1] = isBar ? 255 : g
                pixel[2] = isBar ? 255 : r
                pixel[3] = 255
            }
        }

        return VideoFrame(
            timestamp: FrameTimestamp(
                nanoseconds: index * UInt64(1_000_000_000 / max(1, captureFormat.frameRate))
            ),
            size: PixelSize(width: width, height: height),
            surface: .pixelBuffer(buffer),
            forcesKeyFrame: index == 0
        )
    }

    private static func colour(hue: Double, brightness: Double) -> (UInt8, UInt8, UInt8) {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let peak = brightness
        let trough = brightness * 0.2
        let rising = trough + (peak - trough) * fraction
        let falling = peak - (peak - trough) * fraction

        let (r, g, b): (Double, Double, Double) = switch index {
        case 0: (peak, rising, trough)
        case 1: (falling, peak, trough)
        case 2: (trough, peak, rising)
        case 3: (trough, falling, peak)
        case 4: (rising, trough, peak)
        default: (peak, trough, falling)
        }
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    private static func makePool(size: PixelSize) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        return status == kCVReturnSuccess ? pool : nil
    }

    private static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }
}
