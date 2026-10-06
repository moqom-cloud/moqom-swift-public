import MoqomCore
import MoqomKit
import MoqomUI
import SwiftUI

struct RoomScreen: View {
    @Bindable var room: RoomModel
    let onLeave: () async -> Void

    private var gallery: some View {
        MoqomGalleryView(
            slots: room.slots,
            reportingTo: room.layout,
            aspect: room.seatAspect,
            spacing: 8,
            columns: room.arrangement.columns
        ) { slot in
            switch room.mode {
            case .gallery:
                GalleryTile(slot: slot, room: room)
            case .audioRoom:
                SeatTile(slot: slot, room: room)
            }
        }
    }

    private var overlaidRows: Double {
        Double(min(room.arrangement.columns == nil ? room.slots.count : 1, 3))
    }

    @ViewBuilder private var overflowNote: some View {
        if !room.overflow.isEmpty {
            Label("\(room.overflow.count) more listening in", systemImage: "person.2.wave.2")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if !room.watchdogs.isEmpty {
                WatchdogBanner(watchdogs: room.watchdogs)
                    .padding(.horizontal)
            }

            if !room.forceMuted.isEmpty || !room.resumableAfterForceMute.isEmpty {
                ForceMuteBanner(room: room)
                    .padding(.horizontal)
            }

            if room.participants.isEmpty {
                ContentUnavailableView(
                    "Nobody on stage",
                    systemImage: "person.2.slash",
                    description: Text("Start broadcasting to appear here.")
                )
            } else if room.slots.isEmpty {
                SelfView(room: room, height: nil)
                    .padding(.horizontal, 8)
            } else {
                switch room.isSharing ? .sideBySide : room.screen {
                case .others:
                    gallery
                        .padding(.horizontal, 8)
                    overflowNote

                    if room.isBroadcasting || room.isPublishingAudio {
                        HStack {
                            Spacer()
                            SelfView(room: room, height: 132)
                        }
                        .padding(.horizontal)
                    }

                case .me:
                    ZStack(alignment: .topTrailing) {
                        SelfView(room: room, height: nil)
                        gallery
                            .frame(width: 120, height: 120 / room.seatAspect * overlaidRows)
                            .padding(12)
                    }
                    .padding(.horizontal, 8)
                    overflowNote

                case .sideBySide:
                    GeometryReader { proxy in
                        let half = max((proxy.size.width - 8) / 2, 1)
                        HStack(spacing: 8) {
                            SelfView(room: room, height: nil)
                                .frame(width: half)
                            gallery
                                .frame(width: half)
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    .padding(.horizontal, 8)
                    overflowNote
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            #if canImport(ARKit) && !targetEnvironment(simulator)
                if room.isSharing, room.bubblesFillScreen, let field = room.bubbleField {
                    BubbleOverlayView(field: field)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .top)
                }
            #endif
        }
        .overlay(alignment: .top) {
            if room.isSharing {
                Scoreboard(room: room)
                    .padding(.top, 6)
                    .allowsHitTesting(room.roundIsOver)
            }
        }
        .moqomPictureInPictureSource(room)
        .navigationTitle(room.roomName)
        .safeAreaInset(edge: .bottom) {
            BroadcastControls(room: room)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Room", systemImage: "ellipsis.circle") {
                    Picker("Layout", selection: $room.mode) {
                        ForEach(RoomModel.Mode.allCases) { mode in
                            Text(mode.rawValue).fillsMenuRow().tag(mode)
                        }
                    }

                    Picker("Tiles", selection: $room.boxes) {
                        ForEach([4, 9, 16], id: \.self) { count in
                            Text("\(count)").fillsMenuRow().tag(count)
                        }
                    }

                    Picker("Stage", selection: $room.screen) {
                        ForEach(RoomModel.Screen.allCases) { choice in
                            Text(choice.rawValue).fillsMenuRow().tag(choice)
                        }
                    }

                    Picker("Grid", selection: $room.arrangement) {
                        ForEach(RoomModel.Arrangement.allCases) { choice in
                            Text(choice.rawValue).fillsMenuRow().tag(choice)
                        }
                    }

                    Toggle("Mirror my video", isOn: $room.publishesMirrored)
                        .fillsMenuRow()

                    if room.isSharing {
                        Toggle("Bubbles fill screen", isOn: $room.bubblesFillScreen)
                            .fillsMenuRow()
                            .onChange(of: room.bubblesFillScreen) {
                                room.presentBubbles()
                            }
                            .disabled(!room.canPutBubblesInThePicture)
                    }

                    Picker("In small window", selection: $room.cast) {
                        ForEach(CastChoice.allCases) { choice in
                            Text(choice.rawValue).fillsMenuRow().tag(choice)
                        }
                    }

                    Divider()
                    #if os(iOS)
                        Button {
                            Task { await room.clearBroadcastCard() }
                        } label: {
                            Label("End Lock Screen card", systemImage: "rectangle.badge.xmark")
                                .fillsMenuRow()
                        }
                    #endif

                    Button {
                        Task { await room.attachRecorder() }
                    } label: {
                        Label("Record session", systemImage: "record.circle")
                            .fillsMenuRow()
                    }
                    Button {
                        Task { await room.moderate(.lockStage(true)) }
                    } label: {
                        Label("Lock stage", systemImage: "lock")
                            .fillsMenuRow()
                    }
                    Divider()
                    Button(role: .destructive) {
                        Task { await onLeave() }
                    } label: {
                        Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                            .fillsMenuRow()
                    }
                }
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { room.lastError != nil },
                set: { if !$0 { room.dismissError() } }
            )
        ) {
            Button("OK") { room.dismissError() }
        } message: {
            if let error = room.lastError {
                Text(error.displayString)
            }
        }
    }
}

struct WatchdogBanner: View {
    let watchdogs: [Watchdog]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(watchdogs, id: \.id) { watchdog in
                Label {
                    VStack(alignment: .leading) {
                        Text(watchdog.descriptor).font(.subheadline.weight(.medium))
                        Text(operatorDescription(watchdog.operatedBy))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: icon(for: watchdog.kind))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func icon(for kind: WatchdogKind) -> String {
        switch kind {
        case .recording: "record.circle"
        case .safety: "shield"
        case .analytics: "chart.bar"
        case .compliance: "checkmark.seal"
        case .custom: "eye"
        @unknown default: "eye"
        }
    }

    private func operatorDescription(_ operatedBy: WatchdogOperator) -> String {
        switch operatedBy {
        case .platform: "Operated by MOQOM"
        case .tenant: "Operated by this room's host"
        case let .thirdParty(name): "Operated by \(name)"
        @unknown default: "Operated by a third party"
        }
    }
}

struct ForceMuteBanner: View {
    @Bindable var room: RoomModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.subheadline.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: room.forceMuted.isEmpty ? "hand.raised.slash" : "hand.raised.fill")
            }

            Spacer()

            if !room.resumableAfterForceMute.isEmpty {
                Button("Resume") {
                    Task { await room.resumeAfterForceMute() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            (room.forceMuted.isEmpty ? Color.green : Color.orange).opacity(0.14),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var headline: String {
        room.forceMuted.isEmpty
            ? "A host has unmuted you"
            : "A host muted your \(describe(room.forceMuted))"
    }

    private var detail: String {
        room.forceMuted.isEmpty
            ? "Your \(describe(room.resumableAfterForceMute)) stays off until you turn it back on."
            : "The hardware is off, so nothing is being captured."
    }

    private func describe(_ kinds: MediaKind) -> String {
        var named: [String] = []
        if kinds.contains(.audio) { named.append("microphone") }
        if kinds.contains(.video) { named.append("camera") }
        if kinds.contains(.screenShare) { named.append("screen share") }
        return named.isEmpty ? "media" : named.formatted(.list(type: .and))
    }
}

struct GalleryTile: View {
    let slot: Gallery.Slot
    let room: RoomModel

    var body: some View {
        Group {
            if let participant = room.participant(slot.identity) {
                ParticipantTile(
                    participant: participant,
                    isSelf: false,
                    quality: room.quality(of: slot.identity),
                    room: room
                ) {
                    await room.toggleLocalMute(slot.identity)
                }
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.green, lineWidth: slot.isSpeaking ? 3 : 0)
        }
        .overlay(alignment: .topLeading) {
            if slot.isFeatured {
                Image(systemName: slot.claim == .spotlighted ? "star.fill" : "pin.fill")
                    .font(.caption)
                    .padding(6)
            }
        }
        .animation(.easeOut(duration: 0.15), value: slot.isSpeaking)
        .onTapGesture {
            Task { await room.togglePin(slot.identity) }
        }
    }
}

struct SeatTile: View {
    let slot: Gallery.Slot
    let room: RoomModel

    private var initial: String {
        String(slot.identity.username.value.prefix(1)).uppercased()
    }

    private var isMuted: Bool {
        room.participant(slot.identity)?.mute.effective.contains(.audio) == true
    }

    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(.tertiary)
                .overlay {
                    Text(initial)
                        .font(.title2.weight(.semibold))
                }
                .overlay {
                    Circle().strokeBorder(.green, lineWidth: slot.isSpeaking ? 3 : 0)
                }
                .overlay(alignment: .bottomTrailing) {
                    if isMuted {
                        Image(systemName: "mic.slash.fill")
                            .font(.caption2)
                            .padding(4)
                            .background(.thinMaterial, in: Circle())
                    }
                }
                .animation(.easeOut(duration: 0.15), value: slot.isSpeaking)

            Text(slot.identity.username.value)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(4)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await room.toggleLocalMute(slot.identity) }
        }
    }
}

struct SelfView: View {
    let room: RoomModel

    let height: Double?

    var body: some View {
        if let me = room.participant(room.identity) {
            RemoteVideoView(participant: me, isSelf: true, room: room)
                .aspectRatio(room.seatAspect, contentMode: .fit)
                .frame(height: height.map { CGFloat($0) })
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
                .overlay(alignment: .bottomLeading) {
                    Text("You")
                        .font(.caption2.weight(.semibold))
                        .padding(4)
                        .background(.thinMaterial, in: Capsule())
                        .padding(4)
                }
        }
    }
}

struct ParticipantTile: View {
    let participant: Participant
    let isSelf: Bool

    let quality: String?

    let room: RoomModel

    let onToggleMute: () async -> Void

    var body: some View {
        RemoteVideoView(participant: participant, isSelf: isSelf, room: room)
            .aspectRatio(room.seatAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(participant.slot.identity.username.value)
                            .font(.caption.weight(.semibold))
                        if participant.mute.effective.contains(.audio) {
                            Image(systemName: "mic.slash.fill")
                        }
                        if let quality {
                            Text(quality)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())

                    if let fetching = room.fetching(participant.slot.identity) {
                        Text(
                            "\(fetching.rung) for "
                                + "\(fetching.box.width)×\(fetching.box.height)"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                    }
                }
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                if !isSelf {
                    Button {
                        Task { await onToggleMute() }
                    } label: {
                        Image(
                            systemName: participant.mute.localToMe.contains(.audio)
                                ? "speaker.slash.fill"
                                : "speaker.wave.2.fill"
                        )
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                    .help("Mute for me only")
                }
            }
    }
}

private struct ControlCapsule: ViewModifier {
    let iconOnly: Bool

    func body(content: Content) -> some View {
        Group {
            if iconOnly {
                content.labelStyle(.iconOnly)
            } else {
                content.labelStyle(.titleAndIcon)
            }
        }
        .frame(height: 44)
        .buttonBorderShape(.capsule)
    }
}

private extension View {
    func controlCapsule(iconOnly: Bool = true) -> some View {
        modifier(ControlCapsule(iconOnly: iconOnly))
    }

    func fillsMenuRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

struct Scoreboard: View {
    let room: RoomModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 5) {
                round
                standings
            }
            .lineLimit(1)
            .animation(.spring(duration: 0.25), value: room.roundIsOver)
        }
    }

    @ViewBuilder private var round: some View {
        if room.roundIsOver {
            HStack(spacing: 8) {
                if let winner = room.winner {
                    Text("\(winner.who) wins")
                        .foregroundStyle(.purple)
                } else {
                    Text(room.standings.isEmpty ? "No score" : "Draw")
                }

                Button {
                    Task { await room.rematch() }
                } label: {
                    Text("Rematch")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
                .fixedSize()
                .accessibilityHint("Starts another round on both phones")
            }
            .font(.subheadline.weight(.semibold))
            .capsuled()
        } else if let left = room.secondsLeftInRound {
            HStack(spacing: 5) {
                Image(systemName: "timer")
                    .font(.footnote)
                Text(String(format: "%d:%02d", left / 60, left % 60))
                    .monospacedDigit()
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(left <= 10 ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            .capsuled()
        }
    }

    private var standings: some View {
        HStack(spacing: 10) {
            ForEach(room.standings) { standing in
                HStack(spacing: 4) {
                    Text(standing.who)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("\(standing.score)")
                        .font(.caption.weight(.bold).monospacedDigit())
                }
            }

            if room.standings.isEmpty, !room.roundIsOver {
                Text("Tap the bubbles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Rectangle()
                .fill(.quaternary)
                .frame(width: 1, height: 11)

            Label("\(room.bubblesUp)", systemImage: "circle.hexagongrid")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Image(
                systemName: room.isRunningTheField
                    ? "cpu.fill" : "antenna.radiowaves.left.and.right"
            )
            .font(.caption2)
            .foregroundStyle(room.isRunningTheField ? .purple : .secondary)
            .help(room.isRunningTheField ? "This device is running the field" : "Following")
        }
        .capsuled()
    }
}

private extension View {
    func capsuled() -> some View {
        fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

struct BroadcastControls: View {
    @Bindable var room: RoomModel

    private var shape: Binding<RoomModel.Shape> {
        Binding(
            get: { room.publishShape },
            set: { choice in Task { await room.setPublishShape(choice) } }
        )
    }

    private var fillScreen: Binding<Bool> {
        Binding(
            get: { room.bubblesFillScreen },
            set: { fill in
                room.bubblesFillScreen = fill
                room.presentBubbles()
            }
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Button {
                        Task {
                            if room.isBroadcasting {
                                await room.stopBroadcast()
                                await room.stopAudio()
                            } else {
                                await room.startBroadcast()
                                if room.isBroadcasting, !room.forceMuted.contains(.audio) {
                                    await room.startAudio()
                                }
                            }
                        }
                    } label: {
                        Label(
                            room.isBroadcasting ? "Stop" : "Go live",
                            systemImage: room.isBroadcasting
                                ? "stop.circle.fill"
                                : "dot.radiowaves.left.and.right"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(room.isBroadcasting ? .red : .accentColor)
                    .controlCapsule(iconOnly: false)

                    Button {
                        Task {
                            if room.isPublishingAudio {
                                await room.stopAudio()
                            } else {
                                await room.startAudio()
                            }
                        }
                    } label: {
                        Label(
                            room.isPublishingAudio ? "End audio" : "Audio",
                            systemImage: room.isPublishingAudio ? "waveform.slash" : "waveform"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlCapsule()

                    Button {
                        Task { await room.setMicrophoneMuted(!room.isMicrophoneMuted) }
                    } label: {
                        Label(
                            room.isMicrophoneMuted ? "Unmute" : "Mute",
                            systemImage: room.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(room.isMicrophoneMuted ? .red : nil)
                    .disabled(!room.isPublishingAudio || room.forceMuted.contains(.audio))
                    .controlCapsule()

                    Button {
                        room.capturesEverythingItHears.toggle()
                    } label: {
                        Label(
                            room.capturesEverythingItHears ? "Full range" : "Voice",
                            systemImage: room.capturesEverythingItHears
                                ? "waveform.badge.plus"
                                : "person.wave.2"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(room.capturesEverythingItHears ? .orange : nil)
                    .disabled(!room.isPublishingAudio || room.audioInput != .microphone)
                    .controlCapsule()

                    Button {
                        room.broadcastsToAnAudience.toggle()
                    } label: {
                        Label(
                            room.broadcastsToAnAudience ? "Media volume" : "Call volume",
                            systemImage: room.broadcastsToAnAudience
                                ? "speaker.wave.2"
                                : "phone.arrow.up.right"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(room.broadcastsToAnAudience ? .orange : nil)
                    .disabled(!room.isPublishingAudio && !room.isBroadcasting)

                    Button {
                        room.isPlaybackMuted.toggle()
                    } label: {
                        Label(
                            room.isPlaybackMuted ? "Room silenced" : "Silence room",
                            systemImage: room.isPlaybackMuted
                                ? "speaker.slash.fill"
                                : "speaker.wave.3"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(room.isPlaybackMuted ? .red : nil)
                    .controlCapsule()

                    Button {
                        Task { await room.setCameraMuted(!room.isCameraMuted) }
                    } label: {
                        Label(
                            room.isCameraMuted ? "Camera on" : "Camera off",
                            systemImage: room.isCameraMuted ? "video.slash.fill" : "video.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(room.isCameraMuted ? .red : nil)
                    .disabled(!room.isBroadcasting || room.forceMuted.contains(.video))
                    .controlCapsule()

                    Button {
                        Task { await room.flipCamera() }
                    } label: {
                        Label("Flip", systemImage: "arrow.triangle.2.circlepath.camera")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!room.isBroadcasting || room.videoInput != .camera)
                    .controlCapsule()

                    if room.canShare || room.isSharing {
                        if room.isSharing {
                            Menu {
                                Toggle("Fill screen", isOn: fillScreen)
                                    .fillsMenuRow()
                                Button(role: .destructive) {
                                    Task { await room.stopSharing() }
                                } label: {
                                    Label("Leave bubbles", systemImage: "circle.slash")
                                        .fillsMenuRow()
                                }
                            } label: {
                                Label("Bubbles", systemImage: "circle.hexagongrid.fill")
                            }
                            .menuStyle(.button)
                            .buttonStyle(.bordered)
                            .tint(.purple)
                            .controlCapsule()
                        } else {
                            Button {
                                Task { await room.startSharing() }
                            } label: {
                                Label("Bubbles", systemImage: "circle.hexagongrid.fill")
                            }
                            .buttonStyle(.bordered)
                            .controlCapsule()
                        }
                    }

                    Menu {
                        Picker("Audio", selection: $room.audioInput) {
                            ForEach(RoomModel.AudioInput.allCases) { input in
                                Text(input.rawValue).fillsMenuRow().tag(input)
                            }
                        }

                        Picker("Video", selection: $room.videoInput) {
                            ForEach(room.videoInputs) { input in
                                Text(input.rawValue).fillsMenuRow().tag(input)
                            }
                        }
                        .disabled(room.isBroadcasting)

                        Toggle("Bypass voice processing", isOn: $room.isBypassingVoiceProcessing)
                            .fillsMenuRow()
                            .disabled(!room.isPublishingAudio || room.audioInput != .microphone)
                    } label: {
                        Label("Input", systemImage: "slider.horizontal.3")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .controlCapsule()

                    Menu {
                        Picker("Stage", selection: $room.screen) {
                            ForEach(RoomModel.Screen.allCases) { choice in
                                Text(choice.rawValue).fillsMenuRow().tag(choice)
                            }
                        }

                        Picker("Grid", selection: $room.arrangement) {
                            ForEach(RoomModel.Arrangement.allCases) { choice in
                                Text(choice.rawValue).fillsMenuRow().tag(choice)
                            }
                        }

                        Picker("My video shape", selection: shape) {
                            ForEach(RoomModel.Shape.allCases) { choice in
                                Text(choice.rawValue).fillsMenuRow().tag(choice)
                            }
                        }
                        .disabled(room.videoInput == .scene)

                        Toggle("Mirror my video", isOn: $room.publishesMirrored)
                            .fillsMenuRow()

                        if room.isSharing {
                            Toggle("Bubbles fill screen", isOn: fillScreen)
                                .fillsMenuRow()
                                .disabled(!room.canPutBubblesInThePicture)
                        }
                    } label: {
                        Label("Layout", systemImage: "rectangle.3.group")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .controlCapsule()

                    SceneEffectsMenu()
                        .menuStyle(.button)
                        .buttonStyle(.bordered)
                        .disabled(!room.isBroadcasting)
                        .controlCapsule()
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)

            if room.isPublishingAudio, room.audioInput == .microphone {
                CaptureReadout(meter: room.meter, isCancellingEcho: room.isCancellingEcho)
            }

            if room.isBroadcasting, !room.isPublishingAudio {
                Label("no voice — publishing picture only", systemImage: "waveform.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            LinkReadout(link: room.link, quality: room.quality)

            if !room.participants.filter({ $0.slot.identity != room.identity }).isEmpty {
                GlassReadout(
                    meter: room.latency,
                    wait: room.playoutHold ?? room.playoutDepth.seconds,
                    margin: room.playoutSlack,
                    measured: room.trustedStamp != nil,
                    presentation: room.presentation
                )

                CadenceReadout(meter: room.cadence)
            }

            if let statistics = room.statistics, !statistics.struggling.isEmpty {
                StrugglingReadout(struggling: statistics.struggling)
            }
        }
        .padding(.horizontal)
        .padding(.top)
        .padding(.bottom, 28)
        .background(.bar)
    }
}

struct CaptureReadout: View {
    let meter: AudioMeter
    let isCancellingEcho: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCancellingEcho ? "ear.badge.checkmark" : "ear.trianglebadge.exclamationmark")
                .foregroundStyle(isCancellingEcho ? .green : .orange)
                .accessibilityLabel(
                    isCancellingEcho ? "Echo cancellation on" : "Echo cancellation unavailable"
                )

            Text(reading(meter.level))
                .monospacedDigit()
            Text("floor \(reading(meter.noiseFloor))")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Label("Speaking", systemImage: "waveform.badge.mic")
                .labelStyle(.iconOnly)
                .foregroundStyle(meter.isSpeaking ? .green : .secondary)
                .accessibilityLabel(meter.isSpeaking ? "Speaking" : "Not speaking")
        }
        .font(.caption)
    }

    private func reading(_ decibels: Double) -> String {
        decibels <= VoiceActivity.silent ? "--" : String(format: "%.0f dB", decibels)
    }
}

struct LinkReadout: View {
    let link: LinkStatistics
    let quality: ConnectionQuality

    var body: some View {
        HStack(spacing: 8) {
            QualityBadge(quality: quality)
            Image(systemName: icon)
            Text("\(link.estimate / 1000) kbps")
            if link.objectsLost > 0 {
                Text("· \(link.objectsLost) lost")
            }
            if abs(link.delayTrend) > 0.5 {
                Text(String(format: "· %+.1f ms/s", link.delayTrend))
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var icon: String {
        switch link.state {
        case .increasing: "arrow.up.right.circle"
        case .holding: "equal.circle"
        case .decreasing: "arrow.down.right.circle"
        @unknown default: "circle"
        }
    }
}

struct GlassReadout: View {
    let meter: LatencyMeter

    let wait: Double

    let margin: Double?

    let measured: Bool

    let presentation: VideoRenderer.Presentation?

    @State private var reading: LatencyMeter.Reading?

    @State private var before: VideoRenderer.Presentation?
    @State private var missed: Double?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.metering.matrix")
            if !measured {
                Text(String(format: "%.0f ms", held))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.primary)
                Text("hold · glass-to-glass needs Measure on both devices")
                    .foregroundStyle(.tertiary)
            } else if let reading, reading.worst > 0 {
                Text(String(format: "%.0f ms", reading.median + held))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.primary)
                Text("glass")
                if let missed, missed >= 0.005 {
                    Text(String(format: "· %.0f%% dropped", missed * 100))
                        .foregroundStyle(missed >= 0.05 ? .orange : .secondary)
                }

                Text(String(format: "· link %.0f + hold %.0f ms", reading.median, held))
                    .foregroundStyle(.tertiary)

                if let margin, margin < 0 {
                    Text(String(format: "· %.0f ms late", -margin * 1000))
                        .foregroundStyle(.orange)
                }

                if reading.impossible > 0 {
                    Text("· clocks disagree")
                        .foregroundStyle(.orange)
                }
            } else {
                Text("waiting for the other device")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .task {
            while !Task.isCancelled {
                reading = meter.reading()

                if let now = presentation {
                    let shown = now.total - (before?.total ?? 0)
                    let lost = now.dropped - (before?.dropped ?? 0)
                    if shown > 0 { missed = Double(lost) / Double(shown + lost) }
                    before = now
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var held: Double { max(0, wait * 1000) }
}

struct CadenceReadout: View {
    let meter: CadenceMeter

    @State private var reading: CadenceMeter.Reading?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
            if let reading {
                Text(String(format: "%.0f fps", reading.rate))
                Text(String(format: "· %.0f/%.0f ms gap", reading.median, reading.p95))
                    .foregroundStyle(reading.unevenness > 2 ? .orange : .secondary)
                if reading.freezes > 0 {
                    Text(String(format: "· %d stalls %.0f%%", reading.freezes, reading.frozen * 100))
                        .foregroundStyle(.orange)

                    Text(String(
                        format: "· every %.1fs key %d/%d",
                        reading.period,
                        reading.onKeyFrame,
                        reading.freezes
                    ))
                    .foregroundStyle(.orange)
                }
            } else {
                Text("no frames yet")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .task {
            while !Task.isCancelled {
                reading = meter.reading()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct QualityBadge: View {
    let quality: ConnectionQuality

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(1..<5) { bar in
                Capsule()
                    .fill(bar <= quality.rawValue ? tint : Color.secondary.opacity(0.25))
                    .frame(width: 2.5, height: 3 + Double(bar) * 2)
            }
        }
        .frame(height: 11, alignment: .bottom)
        .accessibilityLabel("Connection \(quality.label)")
    }

    private var tint: Color {
        switch quality {
        case .unknown: .secondary
        case .bad: .red
        case .poor: .orange
        case .good, .excellent: .green
        @unknown default: .secondary
        }
    }
}

struct StrugglingReadout: View {
    let struggling: [ParticipantStatistics]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(names)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var names: String {
        let listed = struggling.prefix(2).map(\.identity.username.value)
        let rest = struggling.count - listed.count
        let joined = listed.joined(separator: ", ")
        return rest > 0
            ? "\(joined) +\(rest) on a weak connection"
            : "\(joined) on a weak connection"
    }
}
