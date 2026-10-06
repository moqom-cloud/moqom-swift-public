import AVFoundation
import Foundation
import MoqomCore
import MoqomKit
import Observation

#if canImport(UIKit)
    import UIKit
#endif

@MainActor
@Observable
final class RoomModel {
    private(set) var participants: [Participant] = []
    private(set) var watchdogs: [Watchdog] = []
    private(set) var stage = StageState()
    var inviteName = ""
    private(set) var lifecycle: RoomLifecycle = .live

    private(set) var isBroadcasting = false {
        didSet { holdTheScreenAwake(isBroadcasting) }
    }

    private(set) var isPublishingAudio = false
    private(set) var lastError: MoqomError?

    #if targetEnvironment(simulator)
        var audioInput: AudioInput = .tone { didSet { swapAudioInput(from: oldValue) } }
    #else
        var audioInput: AudioInput = .microphone { didSet { swapAudioInput(from: oldValue) } }
    #endif

    private func swapAudioInput(from previous: AudioInput) {
        guard audioInput != previous, isPublishingAudio else { return }
        Task {
            await stopAudio(deliberately: false)
            await startAudio()
        }
    }

    private(set) var meter = AudioMeter.quiet

    private(set) var isCancellingEcho = false

    var isBypassingVoiceProcessing: Bool {
        get { AudioGraph.shared.isBypassingVoiceProcessing }
        set { AudioGraph.shared.isBypassingVoiceProcessing = newValue }
    }

    var isPlaybackMuted = false {
        didSet { AudioGraph.shared.playbackVolume = isPlaybackMuted ? 0 : 1 }
    }

    enum AudioInput: String, CaseIterable, Identifiable, Sendable {
        case tone = "Tone"
        case microphone = "Microphone"

        var id: String { rawValue }
    }

    #if targetEnvironment(simulator)
        var videoInput: VideoInput = .pattern
    #else
        var videoInput: VideoInput = .camera
    #endif

    var pinnedRung: VideoLayer?

    var trustedStamp: (@Sendable () -> Timecode)?

    let latency = LatencyMeter()

    let voiceLatency = LatencyMeter()

    let cadence = CadenceMeter()

    let timeline = TimelineMeter()

    let captureCadence = CadenceMeter()

    let bursts = BurstMeter()

    var flatLayers = false

    var encodesEagerly = false

    var capturesPlainly = false

    private let statisticsInterval: Duration

    var playoutDelay: Duration? = .milliseconds(80)

    var playoutBounds: (floor: Duration, ceiling: Duration)? = (
        floor: .zero,
        ceiling: .milliseconds(20)
    )

    var playoutDepth: Duration = .zero

    var playoutTolerance = 0.05

    var playoutSlack: Double?

    var playoutHold: Double?

    var playoutFloorInForce: Duration = .zero

    func audioDelay(of who: ParticipantIdentity) -> Duration? {
        guard let jitter = statistics?.participants[who]?.audio?.targetDelay else { return nil }
        return (heard[who]?.settled ?? jitter) + outputLatency
    }

    var earDelay: Duration {
        let held = heard.values.map(\.settled).max() ?? .zero
        return held + outputLatency
    }

    private var outputLatency: Duration {
        #if os(iOS)
            .seconds(AVAudioSession.sharedInstance().outputLatency)
        #else
            .zero
        #endif
    }

    private(set) var heard: [ParticipantIdentity: AudioPlayer.Playback] = [:]

    var drawing = VideoRenderer.Drawing()

    var tileIsOnScreen = false

    var tileSize: CGSize = .zero

    var tileCount = 0

    var presentation: VideoRenderer.Presentation?

    var previewPresentation: VideoRenderer.Presentation?

    var timing = VideoRenderer.Timing()

    private var captureCadenceTask: Task<Void, Never>?

    var captureBrightness: Double?

    var receivedBrightness: Double?

    var receivedSize: PixelSize?
    var receivedPictures = 0

    private var receivedPictureTask: Task<Void, Never>?
    private var watchedPublisher: ParticipantIdentity?

    var captureSize: PixelSize?

    enum VideoInput: String, CaseIterable, Identifiable, Sendable {
        case pattern = "Test pattern"
        case camera = "Camera"
        case scene = "AR scene"

        var id: String { rawValue }
    }

    var videoInputs: [VideoInput] {
        #if canImport(ARKit) && !targetEnvironment(simulator)
            ARSceneSource.isSupported
                ? VideoInput.allCases
                : VideoInput.allCases.filter { $0 != .scene }
        #else
            VideoInput.allCases.filter { $0 != .scene }
        #endif
    }

    #if canImport(ARKit) && !targetEnvironment(simulator)
        private(set) var arScene: ARSceneSource?

        private(set) var bubbleField: BubbleScene?
    #endif

    private(set) var isSharing = false

    var bubblesFillScreen = true

    var canPutBubblesInThePicture: Bool {
        #if canImport(ARKit) && !targetEnvironment(simulator)
            arScene != nil
        #else
            false
        #endif
    }

    private(set) var isRunningTheField = false

    private(set) var standings: [Score] = []

    private(set) var bubblesUp = 0

    private(set) var round: BubbleField.Round? {
        didSet {
            guard round != oldValue else { return }
            watchTheClock()
        }
    }

    private(set) var roundIsOver = false

    private var whistle: Task<Void, Never>?

    private func watchTheClock() {
        whistle?.cancel()
        whistle = nil
        guard let round else {
            roundIsOver = false
            return
        }
        let left = round.ends &- spaceNow.nanoseconds
        guard left > 0 else {
            roundIsOver = true
            return
        }
        roundIsOver = false
        whistle = Task { [weak self] in
            try? await Task.sleep(for: .nanoseconds(left))
            guard !Task.isCancelled else { return }
            self?.roundIsOver = true
        }
    }

    private var spaceNow: Timecode { trustedStamp?() ?? .fallback() }

    var secondsLeftInRound: Int? {
        guard let round else { return nil }
        let left = round.ends &- spaceNow.nanoseconds
        guard left > 0 else { return nil }
        return Int((left + 999_999_999) / 1_000_000_000)
    }

    var winner: Score? {
        guard roundIsOver, let best = standings.first, best.score > 0 else { return nil }
        guard standings.count == 1 || standings[1].score < best.score else { return nil }
        return best
    }

    struct Score: Identifiable, Hashable {
        var id: String { who }
        let who: String
        let score: Int
    }

    private var space: SpaceSession?
    private var spacePump: Task<Void, Never>?

    var joinsTheFieldWhenLive = true

    var canShare: Bool {
        #if canImport(ARKit) && !targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }

    private(set) var cameraPosition: CameraPosition = .front

    var isPreviewMirrored: Bool {
        guard videoInput == .camera, cameraPosition.wantsMirroredPreview else { return false }
        return !publishesMirrored
    }

    var publishesMirrored = true {
        didSet {
            guard publishesMirrored != oldValue else { return }
            applyMirroring()
        }
    }

    private func applyMirroring() {
        camera?.publishesMirrored = publishesMirrored && cameraPosition.wantsMirroredPreview
    }

    var isMicrophoneMuted: Bool { selfMuted.contains(.audio) }

    var isCameraMuted: Bool { selfMuted.contains(.video) }

    private(set) var selfMuted: MediaKind = []

    private(set) var forceMuted: MediaKind = []

    private(set) var resumableAfterForceMute: MediaKind = []

    private(set) var catalogs: [ParticipantIdentity: Catalog] = [:]

    private(set) var audiences = Audiences()

    var cast: CastChoice = .speaker {
        didSet {
            guard cast != oldValue else { return }
            Task { await room.setPictureInPictureCast(cast.cast) }
        }
    }

    var isInPictureInPicture: Bool {
        #if os(iOS)
            pictureInPicture?.isActive ?? false
        #else
            false
        #endif
    }

    #if os(iOS)
        private(set) var pictureInPicture: MoqomPictureInPicture?

        private var card: BroadcastLiveActivity?
        private var cardTask: Task<Void, Never>?
    #endif

    var mode: Mode = .gallery {
        didSet {
            guard mode != oldValue else { return }
            Task { await applyMode() }
        }
    }

    var boxes = 9 {
        didSet {
            guard boxes != oldValue else { return }
            Task { await applyMode() }
        }
    }

    private(set) var slots: [Gallery.Slot] = []

    private(set) var overflow: [ParticipantIdentity] = []

    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case gallery = "Gallery"
        case audioRoom = "Audio room"

        var id: String { rawValue }
    }

    enum Arrangement: String, CaseIterable, Identifiable, Sendable {
        case automatic = "Automatic"
        case oneUp = "1 across"
        case twoUp = "2 across"
        case threeUp = "3 across"
        case fourUp = "4 across"

        var id: String { rawValue }

        var columns: Int? {
            switch self {
            case .automatic: nil
            case .oneUp: 1
            case .twoUp: 2
            case .threeUp: 3
            case .fourUp: 4
            }
        }
    }

    var arrangement: Arrangement = .automatic

    enum Screen: String, CaseIterable, Identifiable, Sendable {
        case others = "Others"
        case me = "Me, full screen"
        case sideBySide = "Side by side"

        var id: String { rawValue }
    }

    var screen: Screen = .sideBySide

    var seatAspect: Double {
        guard mode == .gallery else { return 1 }
        let size = receivedShape ?? pinnedRung?.size ?? publishSize
        return Double(size.width) / Double(size.height)
    }

    var receivedShape: PixelSize?

    var receivedReshapes = 0

    static let defaultCaptureSize = PixelSize(width: 720, height: 1280)

    static let defaultFrameRate: Double = 30

    var publishSize: PixelSize {
        shaped(PixelSize(width: shortSideForLayout, height: shortSideForLayout * 16 / 9),
               as: publishShape)
    }

    var shortSideForLayout: Int {
        guard let largest = largestTileShortSide else { return Self.defaultShortSide }
        return PublishSizing.shortSide(for: largest)
    }

    private var largestTileShortSide: Int? {
        layout.lastReported.values
            .map { min($0.pixelSize.width, $0.pixelSize.height) }
            .filter { $0 > 0 }
            .max()
    }

    static let defaultShortSide = 720

    private(set) var publishedShortSide: Int?

    func followLayout() {
        guard pinnedRung == nil, let broadcast, isBroadcasting else { return }
        let wanted = shortSideForLayout
        guard wanted != publishedShortSide else { return }

        publishedShortSide = wanted
        let rung = rungForLayout()
        Task { await broadcast.reshape(to: LayerLadder(rungs: [rung])) }

        if case .pattern = videoInput { capture?.resize(to: rung.size) }
    }

    enum Shape: String, CaseIterable, Identifiable, Sendable {
        case upright = "Portrait"
        case sideways = "Landscape"

        var id: String { rawValue }
    }

    var publishShape: Shape = .upright

    func setPublishShape(_ shape: Shape) async {
        publishShape = shape
        let size = shaped(publishSize, as: shape)

        switch videoInput {
        case .camera:
            camera?.rotationDegrees = shape == .upright ? 90 : 0
        case .pattern:
            capture?.resize(to: size)
        case .scene:
            break
        }
    }

    private func shaped(_ size: PixelSize, as shape: Shape) -> PixelSize {
        let short = min(size.width, size.height)
        let long = max(size.width, size.height)
        return shape == .upright
            ? PixelSize(width: short, height: long)
            : PixelSize(width: long, height: short)
    }

    var publishFrameRate: Double = RoomModel.defaultFrameRate

    var publishBitrate: Int {
        let pixels = Double(publishSize.pixelCount)
        let perPixel = 1.36
        let base = pixels * perPixel * (1 + (publishFrameRate / 30 - 1) * 0.6)
        return max(300_000, Int(base.rounded()))
    }

    static let trackName = LayerID("video/camera")

    func rungForLayout() -> VideoLayer {
        let size = publishSize
        return VideoLayer(
            id: Self.trackName,
            size: size,
            frameRate: publishFrameRate,
            bitrate: publishBitrate,
            temporalLayers: 1
        )
    }

    private(set) var statistics: RoomStatistics?

    var link: LinkStatistics { statistics?.link ?? .unknown }

    var quality: ConnectionQuality { statistics?.quality ?? .unknown }

    private(set) var qualities: [ParticipantIdentity: ConnectionQuality] = [:]

    let grants = Grants(publish: .full, moderation: .owner, isOwner: true)

    let identity: ParticipantIdentity
    let layout = LayoutObserver()

    private let session: MoqomSession
    private let room: RoomSession
    private var pump: Task<Void, Never>?
    private var sampler: Task<Void, Never>?
    private var connection: Task<Void, Never>?
    private var capture: PatternSource?
    private var camera: CameraSource?

    var cameraTurn: Double? { camera?.appliedRotationDegrees }

    var cameraTurnsInSoftware: Bool { camera?.softwareTurns ?? false }

    var cameraDelivery: StageLatency? { camera?.deliveryLatency }

    var cameraSensorRate: Double? { camera?.sensorFrameRate }

    private var interruptions: [ParticipantIdentity: MediaKind] = [:]

    var cameraInterruptions: Int { camera?.interruptions ?? 0 }
    var lastCameraInterruption: String? { camera?.lastInterruption }

    private var broadcast: Broadcast?

    private var microphone: AudioRelay?
    private var toneTask: Task<Void, Never>?
    private var mic: MicrophoneSource?
    private var meterTask: Task<Void, Never>?

    private var players: [ParticipantIdentity: AudioPlayer] = [:]
    private var playback: [ParticipantIdentity: Task<Void, Never>] = [:]

    var localeOverride: String? {
        didSet {
            guard localeOverride != oldValue else { return }
            Task { await applyLocale() }
        }
    }

    private(set) var publishedLocale: String?

    private var localeObserver: NSObjectProtocol?

    init(
        session: MoqomSession,
        room: RoomSession,
        identity: ParticipantIdentity,
        locale: String? = nil,
        statisticsInterval: Duration = .milliseconds(250)
    ) {
        self.session = session
        self.room = room
        self.identity = identity
        self.statisticsInterval = statisticsInterval
        self.localeOverride = locale
        layout.bind(to: room)

        layout.onReport = { [weak self] _ in self?.followLayout() }
        #if os(iOS)
            pictureInPicture = MoqomPictureInPicture(room: room, layout: layout)
            pictureInPicture?.onFailure = { [weak self] error in
                self?.lastError = .invalidState(
                    expected: "picture in picture available",
                    actual: error.localizedDescription
                )
            }
        #endif
        start()
        watchPhoneLocale()
        Task { await applyLocale() }
    }

    func applyLocale() async {
        let tag = localeOverride.flatMap(SpokenLocale.normalize) ?? SpokenLocale.current()
        await room.setLocale(tag)
        publishedLocale = await room.locale
        Journal.shared.say("LOCALE own=\(publishedLocale ?? "none")")
    }

    private func watchPhoneLocale() {
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.localeOverride == nil else { return }
                await self.applyLocale()
            }
        }
    }

    var roomName: String { room.room.value }

    var remoteParticipants: [Participant] {
        participants.filter { $0.slot.identity != identity }
    }

    private func start() {
        pump = Task { [weak self, room] in
            for await event in room.events {
                await self?.apply(event)
            }
        }

        Task { [room] in await room.setFollowsPublisher(true) }

        let period = statisticsInterval
        sampler = Task { [weak self, room] in
            for await snapshot in await room.statistics(every: period) {
                self?.observe(snapshot)
            }
        }
        watchConnection()

        Task {
            await applyMode()
            await room.setPictureInPictureCast(cast.cast)
            await refresh()
        }
    }

    private func observe(_ snapshot: RoomStatistics) {
        statistics = snapshot

        for (who, participant) in snapshot.participants {
            guard let audio = participant.audio, let player = players[who] else { continue }
            Task { @MainActor [weak self] in
                await player.aim(at: audio.targetDelay + .milliseconds(20))
                self?.heard[who] = await player.reading()
            }
        }
    }

    private func watchConnection() {
        connection = Task { [weak self, session] in
            for await state in session.states {
                guard self != nil else { return }
                Journal.shared.say("SESSION \(state.description)")
            }
        }
    }

    private func apply(_ event: RoomEvent) async {
        switch event {
        case .watchdogChanged(let set):
            watchdogs = set.all
        case .stageChanged(let updated):
            stage = updated
        case .lifecycleChanged(let updated):
            lifecycle = updated
        case .catalogChanged(let who, let catalog):
            catalogs[who] = catalog
            if catalog.audioTrack != nil { await startPlayback(for: who) }
        case .localeChanged(let who, let locale):
            Journal.shared.say("LOCALE \(who.username.value)=\(locale ?? "none")")
            await refresh()
        case .galleryChanged(let updated):
            slots = updated
            overflow = await room.galleryOverflow
        case .participantLeft(let who, _):
            catalogs.removeValue(forKey: who)
            await stopPlayback(for: who)
            releaseTile(for: who)
            #if os(iOS)
                pictureInPicture?.unregister(who)
            #endif
            await refresh()
        case .audiencesChanged(let updated):
            audiences = updated
        case .broadcastInterrupted:
            lastError = MoqomError.invalidState(
                expected: "a broadcast on a live session",
                actual: "a publication that could not be reopened after reconnecting"
            )
        case .encryptionRequired(let who):
            Journal.shared.say("E2EE required, media refused from \(who.username.value)")
            if who == identity {
                lastError = MoqomError.encryptionRequired
            }
        case .qualityChanged(let who, let quality):
            qualities[who] = quality
        case .pictureInPictureChanged:
            break
        case let .captureRestricted(held, resumable):
            forceMuted = held
            resumableAfterForceMute = resumable
            Journal.shared.say(
                "MUTE held=\(held.rawValue) resumable=\(resumable.rawValue)"
            )
            await refresh()
        case let .muteChanged(who, mute):
            if mute.interrupted != interruptions[who] {
                interruptions[who] = mute.interrupted
                Journal.shared.say(
                    "CAPTURE \(who.username.value) interrupted=\(mute.interrupted.rawValue)"
                )
            }
            await refresh()
        case .participantJoined, .presenceChanged,
             .grantsChanged, .spotlightChanged:
            await refresh()
        case .terminated:
            await leave()
        @unknown default:
            break
        }
    }

    private func refresh() async {
        participants = await room.roster.participants
        slots = await room.galleryLayout
        overflow = await room.galleryOverflow

        selfMuted = await room.selfMuted
    }

    private func applyMode() async {
        switch mode {
        case .gallery:
            await room.setGalleryPolicy(.grid(boxes: boxes))
        case .audioRoom:
            await room.setGalleryPolicy(.audioRoom(seats: max(boxes, 12)))
        }
        applyAudioPurpose()
    }

    var capturesEverythingItHears = false {
        didSet { applyAudioPurpose() }
    }

    var broadcastsToAnAudience = true {
        didSet { applyAudioPurpose() }
    }

    private func applyAudioPurpose(publishing: Bool? = nil) {
        let purpose: AudioGraph.Purpose
        if publishing ?? (isPublishingAudio || isBroadcasting) {
            if capturesEverythingItHears {
                purpose = .music
            } else if broadcastsToAnAudience {
                purpose = .broadcast
            } else {
                purpose = mode == .audioRoom ? .voiceCall : .videoCall
            }
        } else {
            purpose = .listening
        }

        guard AudioGraph.shared.configuration.purpose != purpose else { return }
        do {
            try AudioGraph.shared.reconfigure(
                AudioGraph.Configuration(purpose: purpose)
            )
        } catch {
            lastError = error
        }
    }

    func togglePin(_ target: ParticipantIdentity) async {
        if slots.first(where: { $0.identity == target })?.claim == .pinned {
            await room.unpin(target)
        } else {
            await room.pin(target)
        }
    }

    func isSpeaking(_ target: ParticipantIdentity) -> Bool {
        slots.first { $0.identity == target }?.isSpeaking ?? false
    }

    func participant(_ target: ParticipantIdentity) -> Participant? {
        participants.first { $0.slot.identity == target }
    }

    func quality(of who: ParticipantIdentity) -> String? {
        guard let best = catalogs[who]?.videoLadder.highest else { return nil }
        return "\(min(best.size.width, best.size.height))p"
    }

    func fetching(_ who: ParticipantIdentity) -> (rung: String, box: PixelSize)? {
        guard let box = layout.lastReported[who]?.pixelSize else { return nil }
        let rung = receivedShape.map { "\(min($0.width, $0.height))p" }
        return (rung ?? "—", box)
    }

    func frames(of who: ParticipantIdentity) async -> AsyncStream<DepacketisedFrame>? {
        await room.frames(from: who)
    }

    func codec(of who: ParticipantIdentity) async -> VideoCodec? {
        await room.codec(of: who)
    }

    private func watchCaptureCadence(of publication: Broadcast) {
        captureCadenceTask?.cancel()
        captureCadenceTask = Task { [captureCadence] in
            let tap = await publication.tapFrames(
                policy: TapPolicy(cadence: .everyFrame, depth: 2)
            )
            var seen = 0
            for await frame in tap.elements {
                captureCadence.record()
                seen += 1
                guard seen % 60 == 0 else { continue }
                let luma = Self.brightness(of: frame)
                let size = frame.size
                await MainActor.run {
                    if let luma { self.captureBrightness = luma }
                    self.captureSize = size
                }
            }
        }
    }

    private var tiles: [ParticipantIdentity: VideoTile] = [:]

    private var previewTile: VideoTile?

    func tile(for who: ParticipantIdentity, isSelf: Bool) -> VideoTile {
        if isSelf {
            if let previewTile { return previewTile }
            let tile = VideoTile()
            previewTile = tile
            return tile
        }
        if let existing = tiles[who] { return existing }
        let tile = VideoTile()
        tiles[who] = tile
        return tile
    }

    private func releaseTile(for who: ParticipantIdentity) {
        tiles.removeValue(forKey: who)?.detach()
    }

    func watchReceivedPicture(of who: ParticipantIdentity) {
        guard watchedPublisher != who else { return }
        watchedPublisher = who
        receivedPictureTask?.cancel()
        receivedPictureTask = Task { [weak self] in
            guard let self else { return }
            let tap = await room.tapVideo(from: who, policy: .classification)
            defer { tap.stop() }
            for await picture in tap.elements {
                let luma = Self.brightness(of: picture.frame)
                let size = picture.frame.size
                await MainActor.run {
                    if let luma { self.receivedBrightness = luma }
                    self.receivedSize = size
                    self.receivedPictures += 1
                }
            }
        }
    }

    private static func brightness(of frame: VideoFrame) -> Double? {
        guard case let .pixelBuffer(buffer) = frame.surface else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        guard stride > 0, height > 0, width > 0 else { return nil }

        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var counted = 0
        for row in Swift.stride(from: 0, to: height, by: max(1, height / 16)) {
            for column in Swift.stride(from: 0, to: width, by: max(1, width / 16)) {
                total += Int(pixels[row * stride + column])
                counted += 1
            }
        }
        guard counted > 0 else { return nil }
        return Double(total) / Double(counted) / 255
    }

    func localPreview() async -> MediaTap<VideoFrame>? {
        await broadcast?.tapFrames(policy: TapPolicy(cadence: .everyFrame, depth: 2))
    }

    var invitationsForMe: [StageInvitation] {
        stage.pending.filter {
            $0.outcome == .pending && $0.subject.username == identity.username
        }
    }

    func inviteGuest() async {
        let name = inviteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let username = try? Username(name) else { return }
        do {
            _ = try await room.invite(username)
            Journal.shared.say("INVITE \(name)")
        } catch {
            lastError = error as? MoqomError ?? .invalidState(
                expected: "invite",
                actual: String(describing: error)
            )
        }
    }

    func acceptInvitation(_ id: UUID) async {
        do {
            try await room.accept(id)
            Journal.shared.say("ACCEPT \(id)")
        } catch {
            lastError = error as? MoqomError
        }
    }

    func declineInvitation(_ id: UUID) async {
        do {
            try await room.decline(id)
            Journal.shared.say("DECLINE \(id)")
        } catch {
            lastError = error as? MoqomError
        }
    }

    private func holdTheScreenAwake(_ live: Bool) {
        #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = live
        #endif
    }

    func startBroadcast() async {
        guard !isBroadcasting else { return }

        let rung = pinnedRung ?? rungForLayout()
        publishedShortSide = min(rung.size.width, rung.size.height)

        let size = rung.size
        let format = CaptureFormat(size: size, frameRate: rung.frameRate)

        let source: any FrameSource
        switch videoInput {
        case .pattern:
            let pattern = PatternSource(format: format, label: identity.username.value)
            capture = pattern
            source = pattern
        case .camera:
            do {
                guard await Self.cameraIsAuthorised() else {
                    throw MoqomError.platform(api: "AVCaptureDevice.requestAccess", status: -1)
                }
                let device = try CameraSource(
                    format: format,
                    position: cameraPosition,
                    oversampling: capturesPlainly ? .off : .automatic,
                    logger: MoqomLogger(
                        sink: Journal.diagnostics,
                        minimum: .debug
                    )
                )
                device.start()
                camera = device
                source = device
                applyMirroring()
            } catch {
                lastError = error as? MoqomError
                videoInput = .pattern
                let pattern = PatternSource(format: format, label: identity.username.value)
                capture = pattern
                source = pattern
            }
        case .scene:
            #if canImport(ARKit) && !targetEnvironment(simulator)
                do {
                    guard ARSceneSource.isSupported else { throw ARSceneError.unsupported }
                    guard await Self.cameraIsAuthorised() else {
                        throw MoqomError.platform(
                            api: "AVCaptureDevice.requestAccess", status: -1
                        )
                    }

                    let scene = ARSceneSource(format: format)
                    try scene.start()
                    if bubblesFillScreen { scene.clearPlaceholder() }
                    arScene = scene
                    source = scene

                    screen = .me
                } catch {
                    lastError = error as? MoqomError
                    videoInput = .pattern
                    let pattern = PatternSource(format: format, label: identity.username.value)
                    capture = pattern
                    source = pattern
                }
            #else
                videoInput = .pattern
                let pattern = PatternSource(format: format, label: identity.username.value)
                capture = pattern
                source = pattern
            #endif
        }

        do {
            let ladder = LayerLadder(rungs: [rung])
            let device = camera
            let published = trustedStamp.map {
                TimedSource(source, stamp: $0, floor: { [weak device] in
                    device.map { $0.deliveryLatency.best }
                })
            } ?? source
            var encoders: EncoderFactory = defaultEncoderFactory
            if flatLayers {
                encoders = { configuration in
                    var flat = configuration
                    flat.usesTemporalLayers = false
                    return try await defaultEncoderFactory(flat)
                }
            }
            let publication = try await room.startBroadcast(
                from: published,
                configuration: BroadcastConfiguration(
                    ladder: ladder,
                    prefersPowerEfficiency: !encodesEagerly,
                    encoderFactory: encoders
                )
            )
            await publication.start()
            broadcast = publication
            isBroadcasting = true

            watchCaptureCadence(of: publication)

            Journal.shared.say(
                "GO LIVE source=\(videoInput.rawValue)"
                    + " capture=\(size.width)x\(size.height)@\(Int(format.frameRate))"
                    + " rungs=" + ladder.rungs.map(\.id.value).joined(separator: ",")
                    + " stamp=\(trustedStamp == nil ? "device" : "trusted")"
            )
            applyAudioPurpose()

            if !isPublishingAudio, !hasStoppedAudio { await startAudio() }
            #if os(iOS)
                await startLiveActivity()
            #endif
            if canShare, joinsTheFieldWhenLive { await startSharing() }
            await refresh()
        } catch {
            Journal.shared.say("GO LIVE FAILED source=\(videoInput.rawValue) \(error)")
            lastError = error
            source.stop()
            capture = nil
            camera = nil
            #if canImport(ARKit) && !targetEnvironment(simulator)
                arScene = nil
            #endif
            broadcast = nil
        }
    }

    func startSharing() async {
        #if canImport(ARKit) && !targetEnvironment(simulator)
            guard !isSharing else { return }
            if arScene == nil { bubblesFillScreen = true }
            if bubblesFillScreen { arScene?.clearPlaceholder() }

            let field = BubbleScene()
            field.onPop = { [weak self] id in
                guard let self else { return }
                Task { await self.pop(id) }
            }

            let configuration = SpaceSession.Configuration()
            let stamp = trustedStamp
            bubbleField = field

            do {
                let joined = try await room.joinSpace(
                    BubbleField(),
                    configuration: configuration,
                    clock: { stamp?() ?? .fallback() }
                )
                space = joined
                isSharing = true
                round = BubbleField.round(in: await joined.state)
                field.forget()
                follow(joined, with: field)
                presentBubbles()
                Journal.shared.say("SPACE joined room=\(room.room.value)")
            } catch {
                lastError = error as? MoqomError
                bubbleField = nil
                arScene?.hideField()
            }
        #endif
    }

    func stopSharing() async {
        spacePump?.cancel()
        spacePump = nil
        space = nil
        isSharing = false
        isRunningTheField = false
        standings = []
        bubblesUp = 0
        round = nil
        await room.leaveSpace()
        #if canImport(ARKit) && !targetEnvironment(simulator)
            bubbleField = nil
            arScene?.hideField()
        #endif
    }

    func presentBubbles() {
        #if canImport(ARKit) && !targetEnvironment(simulator)
            guard let field = bubbleField else { return }
            field.placement = bubblesFillScreen
                ? BubbleScene.screenPlacement
                : BubbleScene.tilePlacement
            if bubblesFillScreen {
                field.lockToWorld()
                arScene?.detachField()
            } else if let scene = arScene {
                scene.show(field)
                field.startPresenting(in: scene.view.scene)
            } else {
                bubblesFillScreen = true
                arScene?.clearPlaceholder()
            }
        #endif
    }

    #if canImport(ARKit) && !targetEnvironment(simulator)
        private func follow(_ space: SpaceSession, with field: BubbleScene) {
            spacePump?.cancel()
            spacePump = Task { [weak self] in
                for await event in space.events {
                    guard let self else { return }
                    switch event {
                    case let .changed(state, delta, at: when):
                        field.apply(state, delta, at: when)
                        bursts.observe(delta, in: state, simulated: when, now: spaceNow)
                        standings = BubbleField.standings(in: state).map {
                            Score(who: $0.who, score: $0.score)
                        }
                        bubblesUp = BubbleField.bubbles(in: state).count
                        round = BubbleField.round(in: state)
                    case let .roleChanged(role):
                        isRunningTheField = role == .leading
                        Journal.shared.say("SPACE role=\(role)")
                    case let .authorityChanged(who):
                        field.forget()
                        Journal.shared.say(
                            "SPACE authority=\(who?.username.value ?? "nobody")"
                        )
                    }
                }
            }
        }

        private func pop(_ id: SpaceEntityID) async {
            bursts.askedFor(id)
            await space?.act(verb: BubbleField.pop, subject: id)
        }
    #endif

    func rematch() async {
        await space?.act(verb: BubbleField.rematch)
    }

    @discardableResult
    func popSomething() async -> Bool {
        guard let space else { return false }
        let bubbles = BubbleField.bubbles(in: await space.state)
        guard let target = bubbles.randomElement() else { return false }
        bursts.askedFor(target.id)
        await space.act(verb: BubbleField.pop, subject: target.id)
        return true
    }

    private static func cameraIsAuthorised() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    func flipCamera() async {
        guard let camera else { return }
        let wanted = cameraPosition.flipped
        do {
            try camera.setPosition(wanted)
            cameraPosition = wanted
            applyMirroring()
            await broadcast?.startNewGroup()
        } catch {
            lastError = error as? MoqomError
        }
    }

    func setMicrophoneMuted(_ muted: Bool) async {
        await setSelfMuted(muted ? selfMuted.union(.audio) : selfMuted.subtracting(.audio))
    }

    func setCameraMuted(_ muted: Bool) async {
        await setSelfMuted(muted ? selfMuted.union(.video) : selfMuted.subtracting(.video))
    }

    private func setSelfMuted(_ kinds: MediaKind) async {
        await room.setSelfMuted(kinds)
        selfMuted = await room.selfMuted
    }

    func resumeAfterForceMute() async {
        _ = await room.resumeAfterForceMute()
        resumableAfterForceMute = await room.resumableAfterForceMute
        forceMuted = await room.forceMuted
    }

    private(set) var hasStoppedAudio = false

    func startAudio() async {
        guard !isPublishingAudio else { return }
        hasStoppedAudio = false

        applyAudioPurpose(publishing: true)

        switch audioInput {
        case .tone: await startTone()
        case .microphone: await startMicrophone()
        }

        applyAudioPurpose()

        try? AudioGraph.shared.start()
    }

    private func startMicrophone() async {
        let source: MicrophoneSource
        do {
            source = try MicrophoneSource()
            try source.start()
        } catch {
            lastError = error
            return
        }

        do {
            let published: any AudioSource =
                trustedStamp.map { TimedAudioSource(source, stamp: $0) } ?? source
            let publication = try await room.startAudio(from: published)
            await publication.start()
            isPublishingAudio = true
        } catch {
            lastError = error as? MoqomError
            source.stop()
            return
        }

        mic = source
        isCancellingEcho = source.isCancellingEcho

        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.meter = source.meter
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func startTone() async {
        let relay = AudioRelay()
        microphone = relay

        do {
            let publication = try await room.startAudio(from: relay)
            await publication.start()
            isPublishingAudio = true
        } catch {
            lastError = error
            microphone = nil
            return
        }

        toneTask = Task { [weak self] in
            let format = AudioFormat.voice
            var phase = 0.0
            var timestamp: UInt64 = 0
            let step = 2 * Double.pi * 440 / Double(format.sampleRate)

            var due = ContinuousClock.now
            var packet = 0
            while !Task.isCancelled {
                let speaking = packet % 25 < 15
                packet += 1

                var samples = [Float](repeating: 0, count: format.samplesPerFrame)
                for index in samples.indices {
                    samples[index] = speaking ? Float(sin(phase)) * 0.2 : 0
                    phase += step
                }

                phase.formTruncatingRemainder(dividingBy: 2 * .pi)

                relay.submit(
                    AudioFrame(
                        timestamp: FrameTimestamp(nanoseconds: timestamp),
                        format: format,
                        samples: samples
                    )
                )
                timestamp += 20_000_000
                due += .milliseconds(20)
                try? await Task.sleep(until: due, clock: .continuous)
            }
            _ = self
        }
    }

    private func startPlayback(for who: ParticipantIdentity) async {
        guard who != identity, playback[who] == nil else { return }
        guard let outputs = await room.audio(from: who) else { return }

        let player: AudioPlayer
        do {
            player = try AudioPlayer()
        } catch {
            return
        }
        players[who] = player
        let written = measureVoice()

        playback[who] = Task { [weak self] in
            do throws(MoqomError) {
                try await player.play(outputs, written: written)
            } catch {
                await MainActor.run { self?.lastError = error }
            }

            await self?.finishPlayback(for: who, if: player)
        }
    }

    private func measureVoice() -> (@Sendable (FrameTimestamp) -> Void)? {
        guard let stamp = trustedStamp else { return nil }
        let meter = voiceLatency
        return { captured in meter.record(capturedAt: captured, receivedAt: stamp()) }
    }

    func playback(of who: ParticipantIdentity) -> AudioPlayer.Playback? {
        heard[who]
    }

    private func finishPlayback(for who: ParticipantIdentity, if player: AudioPlayer) async {
        guard players[who] === player else { return }
        players.removeValue(forKey: who)
        playback.removeValue(forKey: who)
        await player.stop()
    }

    private func stopPlayback(for who: ParticipantIdentity) async {
        playback.removeValue(forKey: who)?.cancel()
        if let player = players.removeValue(forKey: who) {
            await player.stop()
        }
        if watchedPublisher == who {
            receivedPictureTask?.cancel()
            receivedPictureTask = nil
            watchedPublisher = nil
        }
    }

    func stopAudio(deliberately: Bool = true) async {
        if deliberately { hasStoppedAudio = true }
        toneTask?.cancel()
        toneTask = nil
        meterTask?.cancel()
        meterTask = nil
        await room.stopAudio()
        mic?.stop()
        mic = nil
        microphone = nil
        isPublishingAudio = false
        isCancellingEcho = false
        meter = .quiet
        applyAudioPurpose()
    }

    func stopBroadcast() async {
        guard isBroadcasting else { return }
        if isSharing { await stopSharing() }
        await room.stopBroadcast()
        capture = nil
        camera = nil
        #if canImport(ARKit) && !targetEnvironment(simulator)
            arScene?.stop()
            arScene = nil
        #endif
        broadcast = nil
        captureCadenceTask?.cancel()
        captureCadenceTask = nil
        isBroadcasting = false
        applyAudioPurpose()
        #if os(iOS)
            endLiveActivity()
        #endif
        await refresh()
    }

    func toggleLocalMute(_ target: ParticipantIdentity) async {
        guard let participant = participants.first(where: { $0.slot.identity == target }) else {
            return
        }
        if participant.mute.localToMe.contains(.audio) {
            await room.localUnmute(target, .audio)
            if catalogs[target]?.audioTrack != nil { await startPlayback(for: target) }
        } else {
            await room.localMute(target, .audio)

            await stopPlayback(for: target)
        }
        await refresh()
    }

    func moderate(_ action: ModerationAction) async {
        do {
            try await room.moderate(action, as: grants)
            await refresh()
        } catch {
            lastError = error
        }
    }

    func attachRecorder() async {
        do {
            try await room.manageWatchdog(
                .attach(
                    WatchdogRequest(
                        kind: .recording,
                        operatedBy: .tenant,
                        descriptor: "Session recording",
                        scope: room.namespace
                    )
                ),
                as: grants
            )
        } catch {
            lastError = error
        }
    }

    func dismissError() { lastError = nil }

    func leave() async {
        toneTask?.cancel()
        toneTask = nil
        pump?.cancel()
        pump = nil
        sampler?.cancel()
        sampler = nil
        connection?.cancel()
        connection = nil
        if let localeObserver {
            NotificationCenter.default.removeObserver(localeObserver)
            self.localeObserver = nil
        }
        #if os(iOS)
            pictureInPicture?.stop()
            endLiveActivity()
        #endif
        for who in playback.keys { await stopPlayback(for: who) }
        await session.close()
    }

    #if os(iOS)
        private func startLiveActivity() async {
            guard BroadcastLiveActivity.isPermitted, card == nil else { return }

            await BroadcastLiveActivity.endAll()

            let card = BroadcastLiveActivity(logger: .silent)
            do {
                try card.start(
                    MoqomBroadcastAttributes(
                        title: "Room \(roomName)",
                        host: identity.username.value,
                        room: room.room
                    ),
                    state: BroadcastActivityState(
                        phase: .live,
                        startedAt: .now,
                        participants: participants.count,
                        quality: quality
                    )
                )
            } catch {
                Journal.shared.say("CARD refused \(error)")
                return
            }

            self.card = card

            cardTask = card.follow(room)
        }

        private func endLiveActivity() {
            cardTask?.cancel()
            cardTask = nil
            card?.end(card?.showing.map { var last = $0; last.phase = .ended; return last })
            card = nil
        }

        func clearBroadcastCard() async {
            endLiveActivity()
            await BroadcastLiveActivity.endAll()
        }
    #endif
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
