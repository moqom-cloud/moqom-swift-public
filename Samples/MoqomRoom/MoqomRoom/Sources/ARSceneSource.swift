#if canImport(ARKit) && !targetEnvironment(simulator)
    import ARKit
    import CoreVideo
    import Metal
    import MetalPerformanceShaders
    import MoqomCore
    import MoqomKit
    import RealityKit
    import SwiftUI
    import VideoToolbox

    enum ARSceneError: Error, CustomStringConvertible {
        case unsupported
        case transferUnavailable(OSStatus)

        var description: String {
            switch self {
            case .unsupported:
                "this device cannot run an AR session"
            case let .transferUnavailable(status):
                "the AR frame could not be scaled to the rung (VTPixelTransfer \(status))"
            }
        }
    }

    final class ARSceneSource: NSObject, FrameSource, @unchecked Sendable {
        let captureFormat: CaptureFormat

        nonisolated(unsafe) let view: ARView

        private let relay: FrameRelay

        private let lock = NSLock()

        private var capture: SceneCapture?
        private var captureSize: PixelSize?
        private var pump: Task<Void, Never>?

        private var sensorFormat: CGSize?

        private var transfer: VTPixelTransferSession?
        private var pool: CVPixelBufferPool?

        nonisolated(unsafe) private var staging: (any MTLTexture)?
        nonisolated(unsafe) private var stagingSize: PixelSize?
        nonisolated(unsafe) private var converter: MPSImageConversion?

        private var lastSubmitted = 0.0
        private var lastRendered = 0.0

        private var interval = 0.0

        private var rendered = 0
        private var published = 0
        private var skipped = 0
        private var isRunning = false

        nonisolated(unsafe) private var orb: ModelEntity?

        @MainActor private(set) var field: BubbleScene?

        @MainActor private var tapping: UITapGestureRecognizer?

        var status: String {
            lock.withLock {
                let sensor = sensorFormat.map { "\(Int($0.width))x\(Int($0.height))" } ?? "default"
                let drawable = captureSize.map { "\($0.width)x\($0.height)" } ?? "not drawn"
                let rate = interval > 0 ? String(format: "%.1f", 1 / interval) : "—"
                return "sensor=\(sensor)"
                    + " \(drawable)→\(captureFormat.size.width)x\(captureFormat.size.height)"
                    + " draws=\(rate)fps rendered=\(rendered)"
                    + " published=\(published) skipped=\(skipped)"
            }
        }

        @MainActor
        init(format: CaptureFormat) {
            captureFormat = format
            relay = FrameRelay(format: format, depth: 3)
            view = ARView(frame: .zero)
            super.init()
        }

        static var isSupported: Bool {
            ARFaceTrackingConfiguration.isSupported || ARWorldTrackingConfiguration.isSupported
        }

        @MainActor
        func start() throws {
            try configureSession()
            buildScene()
            lock.withLock { isRunning = true }

            view.renderCallbacks.postProcess = { [weak self] context in
                guard let self else { return }
                draw(context)
            }
        }

        func stop() {
            let (capture, pump) = lock.withLock {
                let taken = (self.capture, self.pump)
                self.capture = nil
                self.pump = nil
                isRunning = false
                return taken
            }
            pump?.cancel()
            capture?.stop()
            relay.stop()

            Task { @MainActor [weak self] in self?.tearDown() }
        }

        @MainActor
        private func tearDown() {
            view.renderCallbacks.postProcess = nil
            view.session.pause()
        }

        func suspend() {
            guard lock.withLock({ isRunning }) else { return }
            Task { @MainActor [weak self] in self?.view.session.pause() }
        }

        func resume() {
            guard lock.withLock({ isRunning }) else { return }
            Task { @MainActor [weak self] in try? self?.configureSession(resetting: false) }
        }

        func frames() -> AsyncStream<VideoFrame> { relay.frames() }

        private func draw(_ context: ARView.PostProcessContext) {
            defer {
                if let blit = context.commandBuffer.makeBlitCommandEncoder() {
                    blit.copy(from: context.sourceColorTexture, to: context.targetColorTexture)
                    blit.endEncoding()
                }
            }

            guard shouldSubmit(at: context.time) else { return }

            let source = captureable(context.sourceColorTexture, on: context.commandBuffer)
            let drawable = PixelSize(width: source.width, height: source.height)
            guard let capture = capture(for: drawable, device: source.device) else { return }
            capture.submit(
                texture: source,
                at: FrameTimestamp(seconds: context.time),
                on: context.commandBuffer
            )
        }

        private func shouldSubmit(at time: Double) -> Bool {
            let rung = 1 / max(captureFormat.frameRate, 1)
            return lock.withLock {
                rendered += 1
                let gap = time - lastRendered
                lastRendered = time
                if gap > 0, gap < 1 {
                    interval = interval > 0 ? interval * 0.9 + gap * 0.1 : gap
                }

                guard interval > 0, interval < rung * 0.75 else {
                    lastSubmitted = time
                    return true
                }

                guard time - lastSubmitted >= rung * 0.9 else {
                    skipped += 1
                    return false
                }
                lastSubmitted = time
                return true
            }
        }

        private func capture(for drawable: PixelSize, device: any MTLDevice) -> SceneCapture? {
            lock.lock()
            if let capture, captureSize == drawable {
                lock.unlock()
                return capture
            }
            let previous = capture
            lock.unlock()
            previous?.stop()

            guard
                let built = try? SceneCapture(
                    format: CaptureFormat(size: drawable, frameRate: captureFormat.frameRate),
                    device: device,
                    logger: MoqomLogger(
                        sink: Journal.diagnostics,
                        minimum: .warning
                    )
                )
            else { return nil }

            let stream = built.frames()
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                for await frame in stream {
                    guard let self else { return }
                    deliver(frame)
                }
            }

            lock.withLock {
                capture = built
                captureSize = drawable
                pump?.cancel()
                pump = task
            }
            Journal.shared.say(
                "SCENE drawable=\(drawable.width)x\(drawable.height)"
                    + " rung=\(captureFormat.size.width)x\(captureFormat.size.height)"
            )
            return built
        }

        private func captureable(
            _ texture: any MTLTexture, on commandBuffer: any MTLCommandBuffer
        ) -> any MTLTexture {
            switch texture.pixelFormat {
            case .bgra8Unorm, .bgra8Unorm_srgb, .rgba16Float: return texture
            default: break
            }

            let size = PixelSize(width: texture.width, height: texture.height)
            if staging == nil || stagingSize != size {
                let described = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm_srgb,
                    width: size.width,
                    height: size.height,
                    mipmapped: false
                )
                described.usage = [.shaderRead, .shaderWrite, .renderTarget]
                described.storageMode = .private
                staging = texture.device.makeTexture(descriptor: described)
                stagingSize = size
            }
            guard let staging else { return texture }

            if converter == nil {
                converter = MPSImageConversion(
                    device: texture.device,
                    srcAlpha: .alphaIsOne,
                    destAlpha: .alphaIsOne,
                    backgroundColor: nil,
                    conversionInfo: nil
                )
            }
            converter?.encode(
                commandBuffer: commandBuffer, sourceTexture: texture, destinationTexture: staging
            )
            return staging
        }

        private func deliver(_ frame: VideoFrame) {
            guard case let .pixelBuffer(buffer) = frame.surface else { return }
            guard let scaled = scale(buffer) else { return }
            let first = lock.withLock {
                published += 1
                return published == 1
            }
            if first { Journal.shared.say("SCENE sample \(Self.sample(scaled))") }
            relay.submit(
                VideoFrame(
                    timestamp: frame.timestamp,
                    size: captureFormat.size,
                    surface: .pixelBuffer(scaled)
                )
            )
        }

        private func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
            guard let session = try? transferSession(), let pool = try? bufferPool() else {
                return nil
            }

            var destination: CVPixelBuffer?
            guard
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
                == kCVReturnSuccess,
                let destination
            else {
                return nil
            }

            guard
                VTPixelTransferSessionTransferImage(session, from: source, to: destination)
                == noErr
            else { return nil }
            return destination
        }

        private static func sample(_ buffer: CVPixelBuffer) -> String {
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
                return "unreadable"
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

            guard
                let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
            else { return "no planes" }

            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let y = luma.assumingMemoryBound(to: UInt8.self)[
                (rows / 2) * lumaStride + lumaStride / 2
            ]
            let uv = chroma.assumingMemoryBound(to: UInt8.self) + (rows / 4) * chromaStride
                + (chromaStride / 4) * 2

            return "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"
                + " centre y=\(y) u=\(uv[0]) v=\(uv[1])"
        }

        private func transferSession() throws -> VTPixelTransferSession {
            try lock.withLock {
                if let transfer { return transfer }
                var created: VTPixelTransferSession?
                let status = VTPixelTransferSessionCreate(
                    allocator: nil, pixelTransferSessionOut: &created
                )
                guard status == noErr, let created else {
                    throw ARSceneError.transferUnavailable(status)
                }
                VTSessionSetProperty(
                    created,
                    key: kVTPixelTransferPropertyKey_ScalingMode,
                    value: kVTScalingMode_Letterbox
                )
                transfer = created
                return created
            }
        }

        private func bufferPool() throws -> CVPixelBufferPool {
            try lock.withLock {
                if let pool { return pool }
                let attributes: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey:
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferWidthKey: captureFormat.size.width,
                    kCVPixelBufferHeightKey: captureFormat.size.height,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                ]
                var created: CVPixelBufferPool?
                let status = CVPixelBufferPoolCreate(
                    kCFAllocatorDefault, nil, attributes as CFDictionary, &created
                )
                guard status == kCVReturnSuccess, let created else {
                    throw ARSceneError.transferUnavailable(status)
                }
                pool = created
                return created
            }
        }

        @MainActor
        private func configureSession(resetting: Bool = true) throws {
            let options: ARSession.RunOptions =
                resetting ? [.resetTracking, .removeExistingAnchors] : []
            if ARFaceTrackingConfiguration.isSupported {
                let configuration = ARFaceTrackingConfiguration()
                configuration.isWorldTrackingEnabled = false
                trim(configuration, from: ARFaceTrackingConfiguration.supportedVideoFormats)
                view.session.run(configuration, options: options)
            } else if ARWorldTrackingConfiguration.isSupported {
                let configuration = ARWorldTrackingConfiguration()
                trim(configuration, from: ARWorldTrackingConfiguration.supportedVideoFormats)
                view.session.run(configuration, options: options)
            } else {
                throw ARSceneError.unsupported
            }

            view.renderOptions = [
                .disableMotionBlur, .disableDepthOfField, .disableFaceMesh, .disableHDR,
                .disableGroundingShadows, .disablePersonOcclusion,
            ]
            view.automaticallyConfigureSession = false
            view.environment.background = .cameraFeed()
        }

        @MainActor
        private func trim(
            _ configuration: ARConfiguration, from supported: [ARConfiguration.VideoFormat]
        ) {
            configuration.isLightEstimationEnabled = false

            let wanted = captureFormat.size
            let long = Double(max(wanted.width, wanted.height))
            let short = Double(min(wanted.width, wanted.height))

            let fastEnough = supported.filter {
                Double($0.framesPerSecond) >= captureFormat.frameRate - 0.5
            }
            let covering = fastEnough.filter {
                let resolution = $0.imageResolution
                return max(resolution.width, resolution.height) >= long
                    && min(resolution.width, resolution.height) >= short
            }

            let candidates = covering.isEmpty ? fastEnough : covering
            guard
                let format = candidates.min(by: {
                    $0.imageResolution.width * $0.imageResolution.height
                        < $1.imageResolution.width * $1.imageResolution.height
                })
            else { return }

            configuration.videoFormat = format
            lock.withLock { sensorFormat = format.imageResolution }
        }

    @MainActor
    func show(_ field: BubbleScene) {
        self.field = field
        orb?.removeFromParent()
        orb = nil
        field.lockToCamera()
        if !view.scene.anchors.contains(where: { $0 === field.cameraAnchor }) {
            view.scene.addAnchor(field.cameraAnchor)
        }
        installTapHandling()
    }

    @MainActor
    func hideField() {
        field?.clear()
        field?.lockToWorld()
        field = nil
        buildScene()
    }

    @MainActor
    func detachField() {
        field?.lockToWorld()
        field = nil
        clearPlaceholder()
    }

    @MainActor
    func clearPlaceholder() {
        orb?.removeFromParent()
        orb = nil
        if field == nil {
            view.scene.anchors.removeAll()
        }
    }

    @MainActor
    private func installTapHandling() {
        guard tapping == nil else { return }
        let recogniser = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(recogniser)
        tapping = recogniser
    }

    @MainActor
    @objc private func handleTap(_ recogniser: UITapGestureRecognizer) {
        guard let field else { return }
        field.pop(at: recogniser.location(in: view), in: view)
    }

    @MainActor
    private func buildScene() {
        view.scene.anchors.removeAll()
        if let field {
            field.lockToCamera()
            view.scene.addAnchor(field.cameraAnchor)
            let light = DirectionalLight()
            light.light.intensity = 2600
            light.look(at: [0, 0, -0.5], from: [0.4, 0.6, 0], relativeTo: field.root)
            field.root.addChild(light)
            return
        }

        let sphere = ModelEntity(
                mesh: .generateSphere(radius: 0.08),
                materials: [SimpleMaterial(color: .cyan, roughness: 0.15, isMetallic: true)]
            )
            orb = sphere

            let anchor = AnchorEntity(.camera)
            anchor.addChild(sphere)
            sphere.position = [0, -0.05, -0.5]
            view.scene.addAnchor(anchor)

            let light = DirectionalLight()
            light.light.intensity = 2500
            light.look(at: sphere.position, from: [0.4, 0.6, 0], relativeTo: anchor)
            anchor.addChild(light)

            orbit(sphere, around: anchor)
        }

        @MainActor
        private func orbit(_ entity: ModelEntity, around anchor: AnchorEntity) {
            var transform = entity.transform
            transform.translation = [0.12, 0.06, -0.5]
            entity.move(to: transform, relativeTo: anchor, duration: 2, timingFunction: .easeInOut)

            Task { @MainActor [weak self, weak entity, weak anchor] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, let entity, let anchor, lock.withLock({ isRunning }) else { return }
                var back = entity.transform
                back.translation = [-0.12, -0.05, -0.5]
                entity.move(to: back, relativeTo: anchor, duration: 2, timingFunction: .easeInOut)
                try? await Task.sleep(for: .seconds(2))
                guard lock.withLock({ isRunning }) else { return }
                orbit(entity, around: anchor)
            }
        }
    }

    struct ARSceneView: UIViewRepresentable {
        let source: ARSceneSource

        func makeUIView(context _: Context) -> ARView { source.view }
        func updateUIView(_: ARView, context _: Context) {}
    }
#endif
