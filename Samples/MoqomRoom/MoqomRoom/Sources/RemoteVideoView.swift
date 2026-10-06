import AVFoundation
import MoqomCore
import MoqomKit
import SwiftUI

struct RemoteVideoView: View {
    let participant: Participant
    let isSelf: Bool
    let room: RoomModel

    @State private var interruptionBlur = 0.0
    @State private var interruptionFade = 0.0
    @State private var interruptionCaption = 0.0
    @State private var interruptionCover: Task<Void, Never>?
    @State private var interruptionMotion = 0.0

    var body: some View {
        picture
            .background(.black)
            .overlay {
                if participant.presence != .connected {
                    Image(systemName: "person.crop.circle.badge.clock")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                } else if isInterrupted || isCoveringLastFrame {
                    interrupted
                } else if participant.mute.effective.contains(.video) {
                    Image(systemName: "video.slash.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: isInterrupted, initial: true) { was, now in
                interruptionCover?.cancel()
                if was == now {
                    snapInterruption(now)
                } else {
                    interruptionCover = Task { await playInterruption(now) }
                }
            }
            .onDisappear { interruptionCover?.cancel() }
    }

    private var isInterrupted: Bool {
        participant.presence == .connected
            && participant.mute.reason(for: .video) == .interrupted
    }

    private var isCoveringLastFrame: Bool {
        interruptionBlur > 0 || interruptionFade > 0 || interruptionCaption > 0
    }

    private var interrupted: some View {
        ZStack {
            InterruptionBackdrop(blurred: interruptionBlur > 0, duration: interruptionMotion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.black.opacity(interruptionFade)
            VStack(spacing: 6) {
                Image(systemName: "video.badge.ellipsis")
                    .font(.largeTitle)
                Text(isSelf ? "Your camera was interrupted" : "Camera interrupted")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(6)
            .opacity(interruptionCaption)
        }
        .allowsHitTesting(false)
    }

    private func snapInterruption(_ interrupted: Bool) {
        interruptionMotion = 0
        interruptionBlur = interrupted ? 1 : 0
        interruptionFade = interrupted ? 1 : 0
        interruptionCaption = interrupted ? 1 : 0
    }

    private func playInterruption(_ interrupted: Bool) async {
        do {
            if interrupted {
                interruptionMotion = Self.interruptionBlurDuration
                withAnimation(.easeIn(duration: Self.interruptionBlurDuration)) {
                    interruptionBlur = 1
                }
                try await Task.sleep(for: .seconds(Self.interruptionBlurDuration))
                withAnimation(.easeIn(duration: Self.interruptionFadeDuration)) {
                    interruptionFade = 1
                }
                try await Task.sleep(for: .seconds(Self.interruptionFadeDuration))
                withAnimation(.easeOut(duration: Self.interruptionCaptionDuration)) {
                    interruptionCaption = 1
                }
            } else {
                withAnimation(.easeIn(duration: Self.interruptionCaptionDuration)) {
                    interruptionCaption = 0
                }
                try await Task.sleep(for: .seconds(Self.interruptionCaptionDuration))
                interruptionMotion = Self.interruptionFadeDuration
                withAnimation(.easeOut(duration: Self.interruptionFadeDuration)) {
                    interruptionFade = 0
                    interruptionBlur = 0
                }
            }
        } catch {
        }
    }

    private static let interruptionBlurDuration = 0.4
    private static let interruptionFadeDuration = 0.3
    private static let interruptionCaptionDuration = 0.3

    @ViewBuilder
    private var picture: some View {
        #if canImport(ARKit) && !targetEnvironment(simulator)
            if isSelf, room.videoInput == .scene, let scene = room.arScene {
                ARSceneView(source: scene)
            } else {
                layer
            }
        #else
            layer
        #endif
    }

    private var layer: some View {
        VideoLayerView(
            identity: participant.slot.identity,
            isSelf: isSelf,
            isMirrored: isSelf && room.isPreviewMirrored,
            room: room
        )
    }
}

#if os(iOS) || os(visionOS)
    private struct InterruptionBackdrop: UIViewRepresentable {
        var blurred: Bool
        var duration: TimeInterval

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context _: Context) -> UIVisualEffectView {
            let view = UIVisualEffectView(effect: nil)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            return view
        }

        func updateUIView(_ view: UIVisualEffectView, context: Context) {
            guard context.coordinator.blurred != blurred else { return }
            context.coordinator.blurred = blurred
            let effect: UIVisualEffect? = blurred ? UIBlurEffect(style: .dark) : nil
            if duration == 0 {
                view.effect = effect
            } else {
                UIView.animate(
                    withDuration: duration,
                    delay: 0,
                    options: [.curveEaseIn, .beginFromCurrentState]
                ) {
                    view.effect = effect
                }
            }
        }

        final class Coordinator {
            var blurred = false
        }
    }
#elseif os(macOS)
    private struct InterruptionBackdrop: NSViewRepresentable {
        var blurred: Bool
        var duration: TimeInterval

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context _: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.blendingMode = .withinWindow
            view.material = .hudWindow
            view.state = .active
            view.alphaValue = 0
            return view
        }

        func updateNSView(_ view: NSVisualEffectView, context: Context) {
            guard context.coordinator.blurred != blurred else { return }
            context.coordinator.blurred = blurred
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                view.animator().alphaValue = blurred ? 1 : 0
            }
        }

        final class Coordinator {
            var blurred = false
        }
    }
#endif

@MainActor
final class VideoTile {
    let renderer = VideoRenderer()

    private(set) static var live = 0

    private var pump: Task<Void, Never>?

    private var preview: MediaTap<VideoFrame>?

    init() { Self.live += 1 }

    func attachPreview(in room: RoomModel) {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.followPreview(in: room)
                if !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
    }

    private func followPreview(in room: RoomModel) async {
        var tap: MediaTap<VideoFrame>?
        while tap == nil, !Task.isCancelled {
            tap = await room.localPreview()
            if tap == nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard let tap else { return }
        preview?.stop()
        preview = tap
        defer {
            tap.stop()
            preview = nil
        }
        var drawn = 0
        for await frame in tap.elements {
            renderer.enqueue(frame)

            drawn += 1
            if drawn % 30 == 0 {
                Task { @MainActor in
                    if let presentation = await renderer.presentation() {
                        room.previewPresentation = presentation
                    }
                }
            }
        }
    }

    func attach(to identity: ParticipantIdentity, in room: RoomModel) {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.follow(identity, in: room)

                if !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
    }

    private func follow(_ identity: ParticipantIdentity, in room: RoomModel) async {
        var frames: AsyncStream<DepacketisedFrame>?
        while frames == nil, !Task.isCancelled {
            frames = await room.frames(of: identity)
            if frames == nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard let frames else { return }

        await room.watchReceivedPicture(of: identity)

        #if os(iOS)
            renderer.displayRefresh = Self.panelPeriod()
        #endif

        renderer.playoutDelay = await room.playoutDelay
        renderer.playoutBounds = await room.playoutBounds
        renderer.playoutTolerance = await room.playoutTolerance

        if let codec = await room.codec(of: identity) {
            renderer.setCodec(codec)
        }

        let stamp = room.trustedStamp
        let meter = room.latency
        let cadence = room.cadence
        let timeline = room.timeline
        let renderer = renderer

        await Self.drain(
            frames,
            of: identity,
            into: renderer,
            stamp: stamp,
            meter: meter,
            cadence: cadence,
            timeline: timeline,
            reportingTo: room
        )
    }

    private nonisolated static func drain(
        _ frames: AsyncStream<DepacketisedFrame>,
        of identity: ParticipantIdentity,
        into renderer: VideoRenderer,
        stamp: (@Sendable () -> Timecode)?,
        meter: LatencyMeter,
        cadence: CadenceMeter,
        timeline: TimelineMeter,
        reportingTo room: RoomModel
    ) async {
        var drawn = 0
        cadence.restart()
        for await frame in frames {
            if Task.isCancelled { return }
            if let stamp {
                meter.record(capturedAt: frame.frame.timestamp, receivedAt: stamp())
            }
            timeline.record(stamp: frame.frame.timestamp.nanoseconds)
            drawn += 1

            var shown = false
            await MainActor.run {
                let before = renderer.drawing.enqueued
                try? renderer.enqueue(frame)
                shown = renderer.drawing.enqueued > before

                if frame.changesFormat {
                    room.receivedReshapes += 1
                    room.receivedShape = renderer.presentedSize
                } else if room.receivedShape == nil {
                    room.receivedShape = renderer.presentedSize
                }

                room.drawing = renderer.drawing
                room.playoutDepth = renderer.playoutDepth
                room.playoutSlack = renderer.playoutSlack
                room.playoutHold = renderer.playoutHold
                room.tileIsOnScreen = renderer.isOnScreen
                room.tileSize = renderer.drawnSize
                room.tileCount = VideoTile.live
                if drawn % 30 == 0 { room.timing = renderer.timing }
            }

            if shown {
                cadence.record(keyFrame: frame.frame.isKeyFrame)
            }

            if drawn % 30 == 0 {
                Task { @MainActor in
                    if let presentation = await renderer.presentation() {
                        room.presentation = presentation
                    }
                }
            }

            if drawn % 30 == 0 {
                await MainActor.run {
                    guard let bounds = room.playoutBounds else { return }
                    let voice = room.audioDelay(of: identity) ?? .zero
                    let floor = LipSync.floor(voice: voice, bounds: bounds)
                    renderer.playoutFloor = floor

                    room.playoutFloorInForce = floor

                    #if os(iOS)
                        renderer.displayRefresh = Self.panelPeriod()
                    #endif
                }
            }
        }
    }

    #if os(iOS)
        @MainActor
        static func panelPeriod() -> Double {
            if let measured = PanelRate.shared.period, measured > 0 { return measured }
            let hertz = UIScreen.main.maximumFramesPerSecond
            return hertz > 0 ? 1 / Double(hertz) : 1.0 / 60
        }
    #endif

    func detach() {
        pump?.cancel()
        pump = nil
        preview?.stop()
        preview = nil
    }

    deinit {
        pump?.cancel()
        preview?.stop()
        MainActor.assumeIsolated { Self.live -= 1 }
    }
}

#if os(iOS) || os(visionOS)
    private struct VideoLayerView: UIViewRepresentable {
        let identity: ParticipantIdentity
        let isSelf: Bool
        let isMirrored: Bool
        let room: RoomModel

        func makeUIView(context _: Context) -> SampleBufferView {
            SampleBufferView(renderer: start().renderer)
        }

        func updateUIView(_ view: SampleBufferView, context _: Context) {
            view.adopt(start().renderer)
        }

        @discardableResult private func start() -> VideoTile {
            let tile = room.tile(for: identity, isSelf: isSelf)
            tile.renderer.isMirrored = isMirrored
            if isSelf {
                tile.attachPreview(in: room)
            } else {
                tile.attach(to: identity, in: room)
                room.pictureInPicture?.register(tile.renderer, for: identity)
            }
            return tile
        }

    }

    final class SampleBufferView: UIView {
        private var renderer: VideoRenderer

        init(renderer: VideoRenderer) {
            self.renderer = renderer
            super.init(frame: .zero)
        }

        func adopt(_ renderer: VideoRenderer) {
            if renderer !== self.renderer {
                if holdsLayer { self.renderer.layer.removeFromSuperlayer() }
                self.renderer = renderer
            }
            take()
        }

        private var holdsLayer: Bool { renderer.layer.superlayer === layer }

        private func take() {
            guard window != nil else { return }
            if !holdsLayer { layer.addSublayer(renderer.layer) }
            renderer.isHosted = true
            setNeedsLayout()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                take()
            } else if holdsLayer {
                renderer.isHosted = false
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard holdsLayer else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderer.layer.bounds = CGRect(origin: .zero, size: bounds.size)
            renderer.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
    }
#elseif os(macOS)
    private struct VideoLayerView: NSViewRepresentable {
        let identity: ParticipantIdentity
        let isSelf: Bool
        let isMirrored: Bool
        let room: RoomModel

        func makeNSView(context _: Context) -> SampleBufferView {
            SampleBufferView(renderer: start().renderer)
        }

        func updateNSView(_ view: SampleBufferView, context _: Context) {
            view.adopt(start().renderer)
        }

        @discardableResult private func start() -> VideoTile {
            let tile = room.tile(for: identity, isSelf: isSelf)
            tile.renderer.isMirrored = isMirrored
            if isSelf {
                tile.attachPreview(in: room)
            } else {
                tile.attach(to: identity, in: room)
            }
            return tile
        }
    }

    final class SampleBufferView: NSView {
        private var renderer: VideoRenderer

        init(renderer: VideoRenderer) {
            self.renderer = renderer
            super.init(frame: .zero)
            wantsLayer = true
        }

        func adopt(_ renderer: VideoRenderer) {
            if renderer !== self.renderer {
                if holdsLayer { self.renderer.layer.removeFromSuperlayer() }
                self.renderer = renderer
            }
            take()
        }

        private var holdsLayer: Bool { renderer.layer.superlayer === layer }

        private func take() {
            guard window != nil, let host = layer else { return }
            if !holdsLayer { host.addSublayer(renderer.layer) }
            renderer.isHosted = true
            needsLayout = true
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                take()
            } else if holdsLayer {
                renderer.isHosted = false
            }
        }

        override func layout() {
            super.layout()
            guard holdsLayer, let host = layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderer.layer.bounds = CGRect(origin: .zero, size: host.bounds.size)
            renderer.layer.position = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
            CATransaction.commit()
        }
    }
#endif
