import Foundation
import MoqomCore
import MoqomKit
import MoqomLoopback
import Observation

#if os(iOS)
    import AVFAudio
    import QuartzCore
    import UIKit
#endif

@MainActor
@Observable
final class AppModel {
    enum Phase {
        case joining
        case connecting
        case inRoom(RoomModel)
        case failed(MoqomError)
    }

    private(set) var phase: Phase = .joining

    var username: String
    var roomName: String

    var relay = RelayConfiguration.current()

    let launch = LaunchOptions.current()

    #if os(iOS)
        let panelRate = PanelRate.shared
    #endif

    var pairingCode: String

    var measure: Bool

    init(defaults: UserDefaults = .standard) {
        Journal.shared.begin()
        measure = true
        pairingCode = launch.pairingCode ?? defaults.string(forKey: "pairingCode") ?? ""
        username = defaults.string(forKey: "username") ?? ""
        roomName = defaults.string(forKey: "roomName") ?? "demo"
        if !RelayConfiguration.relayHostOverridden {
            relay.useDevelopmentEndpoint()
        }

        #if os(iOS)
            PanelRate.shared.start()
        #endif
    }

    private func remember(to defaults: UserDefaults = .standard) {
        defaults.set(username, forKey: "username")
        defaults.set(roomName, forKey: "roomName")
        defaults.set(pairingCode, forKey: "pairingCode")
        relay.save(to: defaults)
    }

    private var joinedOnLaunch = false

    private var reporter: Task<Void, Never>?

    private var lastPresentation: VideoRenderer.Presentation?

    private var timekeeping: Task<Void, Never>?

    private var popping: Task<Void, Never>?

    private var reshaping: Task<Void, Never>?

    private func reshapeRepeatedly(in room: RoomModel, every seconds: Double) {
        reshaping?.cancel()
        reshaping = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                guard await room.isBroadcasting else { continue }

                let next: RoomModel.Shape = await room.publishShape == .upright
                    ? .sideways
                    : .upright
                await room.setPublishShape(next)
                Journal.shared.say("SHAPE publishing \(next.rawValue.lowercased())")
            }
        }
    }

    private func popRepeatedly(in room: RoomModel, every seconds: Double) {
        popping?.cancel()
        popping = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                if await room.popSomething() { Journal.shared.say("SPACE popped") }
            }
        }
    }

    var canJoin: Bool {
        if case .joining = phase { return !username.trimmed.isEmpty }
        return false
    }

    var relayHost: String {
        get { relay.host ?? "" }
        set { relay.host = newValue.trimmed.isEmpty ? nil : newValue.trimmed }
    }

    var relayCertificateHash: String {
        get { relay.certificateHashes.first ?? "" }
        set {
            relay.certificateHashes = newValue.trimmed.isEmpty ? [] : [newValue.trimmed]
        }
    }

    var relayToken: String {
        get { String(decoding: relay.token, as: UTF8.self) }
        set { relay.token = Data(newValue.trimmed.utf8) }
    }

    var joinHost: String {
        get { relay.tokenService?.host ?? "" }
        set {
            var service = relay.tokenService ?? JoinService.development
            service.host = newValue.trimmed
            relay.tokenService = service
        }
    }

    var joinPort: String {
        get { (relay.tokenService?.port).map(String.init) ?? "443" }
        set {
            var service = relay.tokenService ?? JoinService.development
            service.port = UInt16(newValue.trimmed) ?? service.port
            relay.tokenService = service
        }
    }

    var joinCertificateHash: String {
        get { relay.tokenService?.certificateHashes.first ?? "" }
        set {
            var service = relay.tokenService ?? JoinService.development
            service.certificateHashes = newValue.trimmed.isEmpty ? [] : [newValue.trimmed]
            relay.tokenService = service
        }
    }

    var joinCredential: String {
        get { relay.tokenService?.credential ?? "" }
        set {
            var service = relay.tokenService ?? JoinService.development
            service.credential = newValue.trimmed
            relay.tokenService = service
        }
    }

    var offered: Invitation?

    func offer(_ url: URL) {
        guard let invitation = Invitation(url) else {
            Journal.shared.say("INVITE unreadable \(url.absoluteString.prefix(60))")
            return
        }
        Journal.shared.say("INVITE \(invitation.destination)")
        offered = invitation
    }

    func acceptOffer() {
        guard let invitation = offered else { return }
        offered = nil

        relay = RelayConfiguration(
            host: invitation.relay.endpoint.host,
            port: invitation.relay.endpoint.port,
            certificateHashes: invitation.relay.certificateHashes,
            token: invitation.relay.token,
            tokenService: invitation.relay.tokenService.map {
                JoinService(
                    host: $0.endpoint.host,
                    port: $0.endpoint.port,
                    certificateHashes: $0.certificateHashes,
                    credential: $0.credential
                )
            } ?? relay.tokenService
        )
        pairingCode = ""

        if let credential = invitation.credential {
            if !credential.subject.isEmpty { username = credential.subject }
            if !credential.room.isEmpty { roomName = credential.room }
        }
        remember()
    }

    func declineOffer() { offered = nil }

    var credential: Credential? { relay.credential }

    var credentialComplaint: String? {
        credential?.complaint(
            joining: destinationRoomName(pairing: pairing),
            as: username.trimmed,
            on: deviceName
        )
    }

    private enum Destination {
        case channel
        case watch(String)
        case room(String)
    }

    private var pairing: String? {
        let code = pairingCode.trimmed
        return code.isEmpty ? nil : code
    }

    private func destination(pairing: String?) -> Destination {
        let room = roomName.trimmed
        if room.hasPrefix("@") { return .watch(String(room.dropFirst())) }
        if let launched = launch.room?.trimmed, !launched.isEmpty { return .room(launched) }
        if let pairing { return .room(pairing) }
        if !room.isEmpty { return .room(room) }
        return .channel
    }

    private func destinationRoomName(pairing: String?) -> String {
        switch destination(pairing: pairing) {
        case .channel: return ""
        case let .watch(name): return "@\(name)"
        case let .room(name): return name
        }
    }

    func joinOnLaunch() async {
        prepareDeviceKey()

        username = launch.username ?? username
        roomName = launch.room ?? roomName

        guard launch.autojoin, !joinedOnLaunch else { return }
        joinedOnLaunch = true

        if username.isEmpty { username = "device" }
        Journal.shared.say(
            "JOINING relay=\(relay.summary) room=\(destinationRoomName(pairing: pairing)) as=\(username)"
        )

        await join()

        switch phase {
        case let .inRoom(room):
            Journal.shared.say(
                "JOINED relay=\(relay.summary) room=\(destinationRoomName(pairing: pairing))"
            )
            guard launch.goesLive else { return }

            if let audio = launch.audio {
                switch audio {
                case "mic": room.audioInput = .microphone
                case "tone": room.audioInput = .tone
                default:
                    Journal.shared.say("AUDIO UNKNOWN \(audio) — expected mic or tone; using the microphone")
                    room.audioInput = .microphone
                }
            } else {
                await room.stopAudio()
            }

            await room.startBroadcast()
            guard room.isBroadcasting else {
                Journal.shared.say(
                    "GO LIVE FAILED "
                        + (room.lastError.map(String.init(describing:)) ?? "no reason given")
                )
                return
            }
            if launch.audio != nil, !room.isPublishingAudio {
                Journal.shared.say(
                    "AUDIO FAILED "
                        + (room.lastError.map(String.init(describing:)) ?? "no reason given")
                )
            }

            let live = room.pinnedRung ?? room.rungForLayout()
            Journal.shared.say(
                "LIVE rung=\(live.id.value)"
                    + " \(live.size.width)x\(live.size.height)@\(Int(live.frameRate))"
                    + " \(live.bitrate / 1000)kbps layers=\(live.temporalLayers)"
                    + " codec=hevc source=\(room.videoInput.rawValue)"
                    + " fps=\(Int(launch.frameRate ?? RoomModel.defaultFrameRate))"
                    + " playout=\(launch.playoutMilliseconds.map { "\($0)ms fixed" } ?? "adaptive")"
                    + " layers=\(launch.flatLayers ? "flat" : "temporal")"
                    + " encode=\(launch.eagerEncoding ? "eager" : "efficient")"
                    + " audio=\(room.isPublishingAudio ? (launch.audio ?? "on") : "off")"
                    + " queue=\(launch.bestEffort ? "best-effort" : "interactive-video")"
            )

            if let every = launch.reshapeEverySeconds {
                reshapeRepeatedly(in: room, every: every)
            }

            if launch.bubbles {
                await room.startSharing()
                if let every = launch.popEverySeconds {
                    popRepeatedly(in: room, every: every)
                }
            }
        case let .failed(error): Journal.shared.say("JOIN FAILED \(error)")
        default: Journal.shared.say("JOIN ended in an unexpected state")
        }
    }

    private func discipline(_ clock: TrustedClock) {
        timekeeping?.cancel()
        timekeeping = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                await clock.synchronise()
            }
        }
    }

    private func prepareMeasurement(in room: RoomModel) async {
        if let clock = try? Self.trustedClock() {
            var synchronised = false
            for _ in 0 ..< 12 {
                synchronised = await clock.synchronise() || synchronised
            }
            let now = await clock.now()
            Journal.shared.say(
                synchronised
                    ? "CLOCK synchronised uncertainty=\(now.uncertainty)"
                    : "CLOCK NOT synchronised — latency across devices will be meaningless"
            )
            if synchronised {
                room.trustedStamp = clock.stamp
                discipline(clock)
            }
        } else {
            Journal.shared.say("CLOCK unavailable — latency across devices will be meaningless")
        }

        if let video = launch.video {
            switch video {
            case "pattern": room.videoInput = .pattern
            case "scene", "ar": room.videoInput = .scene
            default: room.videoInput = .camera
            }
        }

        room.joinsTheFieldWhenLive = launch.sharesTheField

        let fps = launch.frameRate ?? RoomModel.defaultFrameRate

        let bitrate = launch.kilobitsPerSecond.map { $0 * 1000 }
            ?? Int(1_250_000 * (1 + (fps / 30 - 1) * 0.6))

        room.publishFrameRate = fps

        guard launch.benchmark else {
            report(on: room)
            return
        }

        room.pinnedRung = VideoLayer(
            id: "video/720p",
            size: RoomModel.defaultCaptureSize,
            frameRate: fps,
            bitrate: bitrate,
            temporalLayers: 1
        )

        report(on: room)
    }

    #if os(iOS)
        private static func describe(_ route: AVAudioSessionRouteDescription) -> String {
            let outputs = route.outputs.map(\.portType.rawValue)
            return outputs.isEmpty ? "none" : outputs.joined(separator: ",")
        }
    #endif

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func charge() -> String {
        #if os(iOS)
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            let state = switch UIDevice.current.batteryState {
            case .charging: "charging"
            case .full: "full"
            case .unplugged: "unplugged"
            default: "unknown"
            }

            guard level >= 0 else { return " charge=pending power=\(state)" }
            return String(format: " charge=%.0f%% power=%@", level * 100, state)
        #else
            return ""
        #endif
    }

    private func report(on room: RoomModel) {
        reporter?.cancel()
        reporter = Task { [weak room] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let room else { return }
                let stats = room.statistics
                Journal.shared.say(
                    "LINK \(room.latency.report())"
                        + " received=\(stats?.link.received ?? 0)bps"
                        + " lost=\(stats?.link.objectsLost ?? 0)"
                        + " quality=\(room.quality)"
                )

                if let link = room.latency.reading(), link.frames > 0 {
                    let wait = (room.playoutHold ?? room.playoutDepth.seconds) * 1000
                    Journal.shared.say(
                        String(
                            format: "GLASS p50=%.0fms p95=%.0fms (link %.0f/%.0f + wait %.0f)",
                            link.median + wait,
                            link.p95 + wait,
                            link.median,
                            link.p95,
                            wait
                        )
                    )
                }

                if let picture = room.latency.reading(), picture.frames > 0,
                   let voice = room.voiceLatency.reading(), voice.frames > 0 {
                    let eye = picture.median + (room.playoutHold ?? room.playoutDepth.seconds) * 1000
                    let ear = voice.median + room.earDelay.seconds * 1000
                    Journal.shared.say(
                        String(
                            format: "SYNC %+.0fms (eye %.0f = link %.0f + wait %.0f,"
                                + " ear %.0f = link %.0f + hold %.0f)",
                            eye - ear,
                            eye,
                            picture.median,
                            eye - picture.median,
                            ear,
                            voice.median,
                            room.earDelay.seconds * 1000
                        )
                    )
                }

                Journal.shared.say("PLAY \(room.cadence.report())")

                if let timeline = room.timeline.report() { Journal.shared.say("TIME \(timeline)") }

                let drawn = room.drawing
                Journal.shared.say(
                    String(
                        format: "DRAW shown=%d notready=%d undescribed=%d failures=%d"
                            + " backwards=%d rebases=%d reanchors=%d regrids=%d delivered=%.1f%%"
                            + " buffer=%.0fms",
                        drawn.enqueued,
                        drawn.skippedNotReady,
                        drawn.skippedUndescribed,
                        drawn.failures,
                        drawn.outOfOrder,
                        drawn.rebases,
                        drawn.reanchors,
                        drawn.regrids,
                        drawn.delivered * 100,
                        room.playoutDepth.seconds * 1000
                    )
                        + String(
                            format: " on-screen=%@ tile=%.0fx%.0f tiles=%d",
                            room.tileIsOnScreen ? "yes" : "no",
                            room.tileSize.width,
                            room.tileSize.height,
                            room.tileCount
                        )
                        + String(
                            format: " shape=%@ reshapes=%d handbacks=%d",
                            room.receivedShape.map { "\($0.width)x\($0.height)" } ?? "unknown",
                            drawn.reshapes,
                            drawn.handbacks
                        )
                        + String(
                            format: " drains=%d refills=%d/%d",
                            drawn.drains, drawn.refills, drawn.observations
                        )
                        + String(
                            format: " gapped=%d crowded=%d stale=%d repaid=%d speed=%d/%.1f%%",
                            drawn.gapped, drawn.crowded, drawn.stale, drawn.reclaimedSlots,
                            drawn.speedShifts, drawn.widestSpeed * 100
                        )
                        + String(
                            format: " grid=%.3f source=%.3f ms phase=%.2f/%.2f ms lead=%.2f/%.0f",
                            drawn.laid * 1000, drawn.arriving * 1000,
                            drawn.phase * 1000, drawn.worstPhase * 1000,
                            drawn.lead, drawn.worstLead
                        )
                        + String(
                            format: " rate=%.2f ahead=%.0fms status=%d%@",
                            room.timing.rate,
                            room.timing.ahead * 1000,
                            room.timing.status,
                            room.timing.needsFlush ? " needs-flush" : ""
                        )
                        + (room.timing.headroom.map {
                            String(format: " headroom=%.0fms", $0 * 1000)
                        } ?? "")
                        + String(format: " pauses=%d dismissed=%d", drawn.pauses, drawn.dismissed)
                        + String(format: " trim=%.0fppm", drawn.trim)
                        + String(
                            format: " floor=%.0fms widen=%d tighten=%d floored=%d reclaim=%d",
                            room.playoutFloorInForce.seconds * 1000,
                            drawn.widenings,
                            drawn.tightenings,
                            drawn.floorRaises,
                            drawn.reclaims
                        )
                )
                if let shown = room.presentation {
                    let before = lastPresentation
                    lastPresentation = shown
                    Journal.shared.say(
                        String(
                            format: "SHOW total=%d dropped=%d corrupted=%d delay=%.1f ms"
                                + " · since=%d dropped=%d",
                            shown.total,
                            shown.dropped,
                            shown.corrupted,
                            shown.delay * 1000,
                            shown.total - (before?.total ?? 0),
                            shown.dropped - (before?.dropped ?? 0)
                        )
                            + (room.previewPresentation.map {
                                String(
                                    format: " · preview total=%d dropped=%d",
                                    $0.total,
                                    $0.dropped
                                )
                            } ?? "")
                    )
                }

                let delivered = (room.cameraDelivery.map {
                    String(
                        format: " deliver p50=%.1f p95=%.1f max=%.1f ms",
                        $0.median,
                        $0.p95,
                        $0.worst
                    )
                } ?? "")
                    + (room.cameraSensorRate.map { String(format: " sensor=%.0f", $0) } ?? "")

                Journal.shared.say(
                    "GRAB \(room.captureCadence.report())"
                        + (room.captureBrightness.map { String(format: " luma=%.3f", $0) } ?? "")
                        + (room.captureSize.map { " size=\($0.width)x\($0.height)" } ?? "")
                        + (room.cameraTurn.map { String(format: " turn=%.0f", $0) } ?? "")
                        + (room.cameraTurnsInSoftware ? "(sw)" : "")
                        + delivered
                        + (room.cameraInterruptions > 0
                            ? " interrupted=\(room.cameraInterruptions)"
                            + (room.lastCameraInterruption.map { " (\($0))" } ?? "")
                            : "")
                )

                if room.receivedPictures > 0 {
                    Journal.shared.say(
                        "SEEN pictures=\(room.receivedPictures)"
                            + (room.receivedBrightness.map { String(format: " luma=%.3f", $0) }
                                ?? "")
                            + (room.receivedSize.map { " size=\($0.width)x\($0.height)" } ?? "")
                    )
                }

                if let audio = stats?.publishing.audio {
                    Journal.shared.say(
                        "TALK captured=\(audio.framesCaptured)"
                            + " published=\(audio.packetsPublished)"
                            + " dropped=\(audio.packetsDropped)"
                            + " silent=\(audio.silentPackets)"
                            + String(
                                format: " grab p50=%.1f p95=%.1f max=%.1f",
                                audio.captureSpacing.median,
                                audio.captureSpacing.p95,
                                audio.captureSpacing.worst
                            )
                            + String(
                                format: " · send p50=%.1f p95=%.1f max=%.1f ms",
                                audio.publishSpacing.median,
                                audio.publishSpacing.p95,
                                audio.publishSpacing.worst
                            )
                    )
                }
                #if os(iOS)
                    let session = AVAudioSession.sharedInstance()
                    Journal.shared.say(
                        "OUT engine=\(AudioGraph.shared.isRunning ? "running" : "stopped")"
                            + " input=\(AudioGraph.shared.isMicrophoneSuspended ? "given back" : "held")"
                            + " route=\(Self.describe(session.currentRoute))"
                            + String(format: " io=%.1fms", session.ioBufferDuration * 1000)
                            + String(
                                format: " out=%.0fms in=%.0fms",
                                session.outputLatency * 1000,
                                session.inputLatency * 1000
                            )
                            + String(
                                format: " late=%.0fms",
                                AudioGraph.shared.capturedLate.seconds * 1000
                            )
                            + " volume=\(String(format: "%.2f", session.outputVolume))"
                            + " mode=\(session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""))"
                + " category=\(session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: ""))"
                + String(format: " mix=%.2f", AudioGraph.shared.playbackVolume)
                + String(
                    format: " heard=%.1fdB room=%.1fdB sent=%.1fdB",
                    AudioGraph.shared.meter.level,
                    AudioGraph.shared.meter.noiseFloor,
                    AudioGraph.shared.outputLevel
                )
                            + " mic=\(AVAudioApplication.shared.recordPermission == .granted ? "granted" : "not granted")"
                            + (room.lastError.map { " error=\($0)" } ?? "")
                    )
                #endif

                for (who, participant) in stats?.participants ?? [:] {
                    guard let heard = participant.audio else { continue }
                    Journal.shared.say(
                        String(
                            format: "HEAR %@ received=%d played=%d late=%d duplicate=%d gaps=%d"
                                + " target=%.0fms jitter=%.1fms interrupted=%d spacing=%.0fms",
                            String(describing: who.username),
                            heard.packetsReceived,
                            heard.packetsPlayed,
                            heard.packetsLate,
                            heard.packetsDuplicate,
                            heard.gaps,
                            heard.targetDelay.seconds * 1000,
                            heard.jitter.seconds * 1000,
                            heard.discontinuities,
                    heard.worstSpacing * 1000
                        )
                    )

                    if let played = room.playback(of: who) {
                        Journal.shared.say(
                            String(
                                format: "  SPKR %@ buffers=%d silent=%d peak=%.3f"
                                    + " decoded=%d failed=%d gaps=%d silences=%d"
                                    + " queued=%.0fms target=%.0fms settled=%.0fms"
                                    + " covering=%.0fms pace=%.0fms"
                                    + " trimmed=%d dropped=%d starved=%d",
                                String(describing: who.username),
                                played.buffers,
                                played.silent,
                                played.peak,
                                played.decoding.packets,
                                played.decoding.failures,
                                played.decoding.gaps,
                                played.decoding.silences,
                                played.queued.seconds * 1000,
                                played.target.seconds * 1000,
                                played.settled.seconds * 1000,
                                played.covering.seconds * 1000,
                                played.pacing.seconds * 1000,
                                played.trimmed,
                                played.dropped,
                                played.starved
                            )
                        )
                    }
                }

                var panel = ""
                #if os(iOS)
                    if let period = panelRate.period, period > 0 {
                        panel = String(
                            format: " panel=%.0fHz slowest=%.0fHz",
                            1 / period,
                            1 / (panelRate.longest ?? period)
                        )
                    }
                #endif

                Journal.shared.say(
                    "HOST thermal=\(Self.describe(ProcessInfo.processInfo.thermalState))"
                        + " lowpower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
                        + panel + Self.charge()
                )

                if let video = stats?.publishing.video {
                    Journal.shared.say(
                        "SEND submitted=\(video.framesSubmitted)"
                            + " encoded=\(video.framesEncoded)"
                            + " dropped=\(video.framesDropped)"
                            + " muted=\(video.framesMuted)"
                            + " unroutable=\(video.framesUnroutable)"
                            + " objects=\(video.objectsPublished)"
                            + (video.encodersRebuilt > 0
                                ? " rebuilt=\(video.encodersRebuilt)" : "")
                            + (video.reshapes > 0 || video.reshapesAbandoned > 0
                                ? " reshapes=\(video.reshapes)"
                                    + " out-of-shape=\(video.framesOutOfShape)"
                                    + " abandoned=\(video.reshapesAbandoned)"
                                : "")
                            + " · encoder emitted=\(video.encoding.emitted)"
                            + " declined=\(video.encoding.declined)"
                            + " unreadable=\(video.encoding.unreadable)"
                            + " overrun=\(video.encoding.overrun)"
                    )

                    #if canImport(ARKit) && !targetEnvironment(simulator)
                        if let scene = room.arScene {
                            Journal.shared.say("SCENE \(scene.status)")
                        }
                    #endif

                    if room.isSharing {
                        let scores = room.standings
                            .map { "\($0.who)=\($0.score)" }
                            .joined(separator: " ")
                        let round = room.round.map {
                            " round=\($0.number)"
                                + (room.roundIsOver
                                    ? " over"
                                    : " left=\(room.secondsLeftInRound ?? 0)s")
                        } ?? " round=none"
                        Journal.shared.say(
                            "SPACE role=\(room.isRunningTheField ? "authority" : "follower")"
                                + round
                                + " bubbles=\(room.bubblesUp)"
                                + (scores.isEmpty ? "" : " · \(scores)")
                        )

                        if let bursts = room.bursts.report() {
                            Journal.shared.say("BURST \(bursts)")
                        }
                    }

                    Journal.shared.say(
                        String(
                            format: "COST encode p50=%.1f p95=%.1f max=%.1f ms"
                                + " · write p50=%.1f p95=%.1f max=%.1f ms",
                            video.encodeLatency.median,
                            video.encodeLatency.p95,
                            video.encodeLatency.worst,
                            video.writeLatency.median,
                            video.writeLatency.p95,
                            video.writeLatency.worst
                        )
                    )
                }

                for who in room.participants.map(\.slot.identity)
                    where who != room.identity
                {
                    let mine = stats?.participants[who]
                    let box = room.layout.lastReported[who]
                    Journal.shared.say(
                        "  VIEW \(who.username.value)"
                            + " rung=\(mine?.layer?.value ?? "none")"
                            + " box=\(box.map { "\($0.pixelSize.width)x\($0.pixelSize.height)" } ?? "unreported")"
                            + " frames=\(mine?.video?.framesProduced ?? 0)"
                            + " nokey=\(mine?.video?.objectsAwaitingKeyFrame ?? 0)"
                            + " offers=\(room.catalogs[who]?.videoLadder.rungs.map(\.id.value).joined(separator: ",") ?? "no catalog")"
                            + " silent=\(mine?.silentFor.map { "\($0)" } ?? "never arrived")"
                    )
                }
            }
        }
    }

    private(set) var deviceKey: DeviceKey?

    private(set) var deviceProblem: String?

    var deviceName: String {
        deviceKey.map { DeviceID.field(of: $0.thumbprint) } ?? "unkeyed-device"
    }

    func prepareDeviceKey() {
        guard deviceKey == nil else { return }
        do {
            let key = try DeviceKey.installed()
            deviceKey = key
            Journal.shared.say(
                "DEVICE key in the \(key.storage), thumbprint \(key.thumbprint)"
            )
        } catch {
            deviceProblem = String(describing: error)
            Journal.shared.say("DEVICE no key: \(deviceProblem ?? "")")
        }
    }

    private(set) var tokenProblem: String?

    var tenant: String {
        guard let claimed = Credential(relay.token)?.tenant, !claimed.isEmpty else {
            return launch.tenant
        }
        return claimed
    }

    private func fetchATokenIfNeeded() async -> Bool {
        tokenProblem = nil

        let room = destinationRoomName(pairing: pairing)
        let name = username.trimmed
        guard let service = relay.tokenService, service.isUsable else {
            if relay.host != nil, relay.needsAToken(joining: room, as: name, on: deviceName) {
                Journal.shared.say("TOKEN stale and no service configured")
            }
            return true
        }
        guard relay.needsAToken(joining: room, as: name, on: deviceName) else { return true }

        guard let deviceKey else {
            tokenProblem = "This device has no key, so no token can be bound to it."
            Journal.shared.say("TOKEN not asked for: no device key")
            return false
        }

        Journal.shared.say("TOKEN asking \(service.host):\(service.port) for \(name) in \(room)")
        do {
            let issued = try await service.client().token(
                username: name,
                room: room,
                device: deviceKey
            )
            relay.token = issued.token
            if !issued.username.isEmpty { username = issued.username }
            Journal.shared.say(
                "TOKEN got one for \(issued.username) in \(issued.room),"
                    + " good for \(Int(issued.expiresAt.timeIntervalSinceNow))s"
            )
            return true
        } catch {
            let complaint = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            tokenProblem = complaint
            Journal.shared.say("TOKEN FAILED \(complaint)")
            phase = .joining
            return false
        }
    }

    private static func trustedClock() throws -> TrustedClock {
        TrustedClock(
            authority: NTPAuthority(exchange: try UDPExchange.apple())
        )
    }

    func join() async {
        guard canJoin else { return }
        phase = .connecting

        let sharedCode = pairing
        if !RelayConfiguration.loopbackRequested,
           !RelayConfiguration.relayHostOverridden || relay.host == nil {
            relay.useDevelopmentEndpoint()
        }

        if !(await fetchATokenIfNeeded()) { return }

        remember()

        do {
            let identity = try ParticipantIdentity(
                username: Username(username.trimmed),
                device: DeviceID(deviceName)
            )
            var renew: (@Sendable () async throws -> IssuedToken)?
            if let mint = relay.tokenService.flatMap({ $0.isUsable ? $0.client() : nil }),
               let key = deviceKey {
                let asking = username.trimmed
                let joining = destinationRoomName(pairing: sharedCode)
                renew = {
                    try await mint.token(username: asking, room: joining, device: key)
                }
            }

            let session = MoqomSession(
                transport: relay.transport(bestEffort: launch.bestEffort),
                credentials: DeviceCredentials(
                    identity: identity,
                    token: relay.token,
                    deviceKey: deviceKey,
                    expiresAt: renew == nil ? nil : Credential(relay.token)?.expires,
                    renew: renew
                ),
                tenant: TenantID(tenant),
                logger: MoqomLogger(
                    sink: BroadcastLogSink(sinks: [
                        Journal.diagnostics,
                        Journal.Sink(minimum: .warning),
                    ]),
                    minimum: launch.quietLogs ? .warning : .debug
                )
            )
            try await session.connect(to: relay.endpoint)
            let room: RoomSession
            switch destination(pairing: sharedCode) {
            case .channel:
                room = try await session.goLive()
            case let .watch(name):
                room = try await session.watch(try Username(name))
            case let .room(name):
                room = try await session.join(room: RoomID(name))
            }
            await room.useEncryption(
                RoomKey.encryption(room: room.room, passphrase: launch.roomKey ?? RoomKey.samplePassphrase)
            )
            let model = RoomModel(
                session: session,
                room: room,
                identity: identity,
                locale: launch.locale,
                statisticsInterval: launch.statisticsMilliseconds
                    .map { .milliseconds($0) } ?? .milliseconds(250)
            )
            model.flatLayers = launch.flatLayers
            model.encodesEagerly = launch.eagerEncoding
            model.capturesPlainly = launch.plainCapture
            if let mediaVolume = launch.mediaVolume {
                model.broadcastsToAnAudience = mediaVolume
            }
            model.isPlaybackMuted = launch.silenceRoom
            if let mix = launch.mix {
                AudioGraph.shared.monitorOutput()
                AudioGraph.shared.playbackVolume = mix
            }

            if let playout = launch.playoutMilliseconds {
                model.playoutBounds = nil
                model.playoutDelay = playout > 0 ? .milliseconds(playout) : nil
            }
            if let tolerance = launch.playoutTolerance {
                model.playoutTolerance = tolerance
            }
            if let floor = launch.playoutFloorMilliseconds, var bounds = model.playoutBounds {
                bounds.floor = .milliseconds(floor)
                model.playoutBounds = bounds
            }
            if measure { await prepareMeasurement(in: model) }
            phase = .inRoom(model)

            if sharedCode != nil, !launch.autojoin {
                await model.startBroadcast()
                await model.startAudio()
            }
        } catch let error as MoqomError {
            phase = .failed(error)
        } catch let error as NameError {
            phase = .failed(.invalidName(error))
        } catch {
            phase = .failed(.transport(.unreachable))
        }
    }

    func leave() async {
        reporter?.cancel()
        timekeeping?.cancel()
        timekeeping = nil
        popping?.cancel()
        popping = nil
        reshaping?.cancel()
        reshaping = nil
        if case let .inRoom(model) = phase {
            await model.leave()
        }
        phase = .joining
    }

    func dismissError() {
        phase = .joining
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

#if os(iOS)
    @MainActor
    final class PanelRate {
        static let shared = PanelRate()

        private var link: CADisplayLink?
        private var periods: [Double] = []
        private var cursor = 0

        private static let window = 120

        private(set) var period: Double?
        private(set) var longest: Double?

        func start() {
            guard link == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick))

            let hertz = Float(UIScreen.main.maximumFramesPerSecond)
            if hertz > 0 {
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: min(60, hertz),
                    maximum: hertz,
                    preferred: hertz
                )
            }

            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            let elapsed = link.targetTimestamp - link.timestamp
            guard elapsed > 0 else { return }

            if periods.count < Self.window {
                periods.append(elapsed)
            } else {
                periods[cursor] = elapsed
                cursor = (cursor + 1) % Self.window
            }

            let sorted = periods.sorted()
            period = sorted[sorted.count / 2]
            longest = sorted[sorted.count - 1]
        }
    }
#endif
