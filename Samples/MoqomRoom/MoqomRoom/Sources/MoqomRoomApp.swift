import MoqomKit
import SwiftUI

@main
struct MoqomRoomApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                switch model.phase {
                case .joining:
                    JoinScreen(model: model)
                case .connecting:
                    ProgressView("Connecting")
                        .navigationTitle("MOQOM")
                case let .inRoom(room):
                    RoomScreen(room: room) {
                        await model.leave()
                    }
                case let .failed(error):
                    FailureScreen(error: error) {
                        model.dismissError()
                    }
                }
            }
            .task { await model.joinOnLaunch() }
            .onOpenURL { model.offer($0) }
        }
    }
}

struct JoinScreen: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            if let invitation = model.offered {
                InvitationSection(invitation: invitation, model: model)
            }

            Section {
                TextField("Username", text: $model.username)
                    .textContentType(.username)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } header: {
                Text("You")
            } footer: {
                DeviceKeyFooter(model: model)
            }

            Section {
                TextField("Pairing code", text: $model.pairingCode)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif

                TextField("Room or @username", text: $model.roomName)
            } header: {
                Text("Call")
            } footer: {
                Text(
                    "Share the pairing code. Both phones join that call and go live. "
                        + "@ada watches ada. A room name is used only when the code is empty."
                )
            }

            Section {
                TextField("Relay host", text: $model.relayHost)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()

                TextField("Port", value: $model.relay.port, format: .number.grouping(.never))
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif

                TextField("Certificate hash", text: $model.relayCertificateHash)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
            } header: {
                Text("Relay")
            } footer: {
                Text(
                    "The relay this build is configured with (MOQOM_RELAY_HOST). Empty "
                        + "runs on the in-memory loopback. A pairing code names the call "
                        + "on that relay."
                )
            }

            Section {
                TextField("Token service host", text: $model.joinHost)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()

                TextField("Port", text: $model.joinPort)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif

                TextField("Certificate hash", text: $model.joinCertificateHash)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())

                SecureField("Device credential", text: $model.joinCredential)
                    .font(.caption.monospaced())
            } header: {
                Text("Token service")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let problem = model.tokenProblem {
                        Text(problem).foregroundStyle(.orange)
                    }
                    Text(model.relay.tokenService?.summary ?? "none")
                    Text(
                        "With this filled in, the phone fetches its own token just before "
                            + "it connects and replaces it mid-call, so neither this nor the "
                            + "call expires. The credential is not a token: it grants joining "
                            + "rooms in one tenant, never moderation or ownership, and it is "
                            + "kept in the Keychain."
                    )
                }
            }

            Section {
                TextField("Token", text: $model.relayToken, axis: .vertical)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .lineLimit(1 ... 3)
                    .font(.caption.monospaced())
            } header: {
                Text("Pasted token")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let complaint = model.credentialComplaint {
                        Text(complaint).foregroundStyle(.orange)
                    }
                    if let credential = model.credential {
                        Text(credential.summary)
                    } else if model.relayToken.isEmpty {
                        Text(
                            model.relay.tokenService?.isUsable == true
                                ? "Empty, and it does not need filling in: one will be "
                                    + "fetched when you join."
                                : "Without one, a deployed relay admits this device and lets "
                                    + "it publish nothing. Mint one on your server with a MOQOM API "
                                    + "key and paste it here; it is kept for this relay and this "
                                    + "phone."
                        )
                    } else {
                        Text("That does not read as a token.").foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Toggle("Measure this run", isOn: $model.measure)

                Button("Join") {
                    Task { await model.join() }
                }
                .disabled(!model.canJoin)
            } footer: {
                Text(
                    "Relay: \(model.relay.summary)."
                        + (model.measure
                            ? " Stamps both phones on a shared clock and reports how long "
                                + "the far side's frames take to arrive."
                            : "")
                )
            }
        }
        .navigationTitle("MOQOM")
    }
}

struct DeviceKeyFooter: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem = model.deviceProblem {
                Text("No device key: \(problem). Tokens cannot be bound to this phone.")
                    .foregroundStyle(.orange)
            }
            if let key = model.deviceKey {
                Text(model.deviceName).font(.caption.monospaced())
                Text(
                    key.storage == .secureEnclave
                        ? "Key in the Secure Enclave, so a copied token is useless without "
                            + "this phone."
                        : "Key in the Keychain — the Secure Enclave was unavailable, so this "
                            + "key could be read off the device."
                )
            }
        }
    }
}

struct InvitationSection: View {
    let invitation: Invitation
    let model: AppModel

    var body: some View {
        Section {
            Button("Use this relay") { model.acceptOffer() }
            Button("Ignore", role: .cancel) { model.declineOffer() }
        } header: {
            Text("Scanned link")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Would connect to \(invitation.destination).").bold()
                Text(invitation.identification)
                if invitation.isStale {
                    Text("Its credential has already expired — ask for a fresh link.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

struct FailureScreen: View {
    let error: MoqomError
    let onDismiss: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Could not join", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.displayString)
        } actions: {
            Button("Try again", action: onDismiss)
        }
    }
}

extension MoqomError {
    var displayString: String {
        switch self {
        case let .invalidName(reason):
            "That name will not work: \(reason)."
        case .transport:
            "Could not reach the relay."
        case let .rejected(reason):
            "The relay refused: \(reason)."
        case .invalidState:
            "The app got ahead of itself."
        case let .terminated(event):
            event.defaultDisplayString
        case let .notPermitted(capability):
            "You do not have permission (\(capability))."
        case let .unsupportedCodec(codec):
            "This device cannot handle \(codec.rawValue)."
        case let .unsupportedAudioCodec(codec):
            "This device cannot handle \(codec.rawValue) audio."
        case .protocolViolation:
            "The relay is speaking a protocol this app does not understand."
        case .encryptionFailed:
            "Could not encrypt the stream, so nothing was sent."
        case .encryptionRequired:
            "This room requires end-to-end encryption and no key is set, so nothing was sent."
        case let .platform(api, status):
            "\(api) failed with \(status)."
        @unknown default:
            "Something went wrong."
        }
    }
}
