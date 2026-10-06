# MoqomKit

The Apple-platform client SDK for [MOQOM](https://moqom.cloud), media over QUIC
for live rooms and broadcasts. iOS, iPadOS, macOS, visionOS and tvOS 26.

Documentation: [moqom.dev](https://moqom.dev), starting with the
[iOS & macOS guide](https://moqom.dev/guides/ios-macos/).

## What is in this repository

This repository is the public, Apache-2.0 part of the SDK:

| Path | What it is |
| --- | --- |
| `Package.swift` | The Swift package. The core modules are prebuilt XCFrameworks attached to each [release](https://github.com/moqom-cloud/moqom-swift/releases). |
| `Sources/MoqomUI` | SwiftUI components, in source: `MoqomGalleryView`. |
| `Samples/MoqomRoom` | A complete iOS app: join a room, publish, watch, Picture in Picture, Live Activity. |
| `Tests` | Tests that exercise the public API. |
| `Scripts/build-xcframeworks.sh` | How the release binaries are built (needs the private core sources). |

The core modules (`MoqomCore`, `MoqomWire`, `MoqomKit`, `MoqomLoopback`) are
not open source. They ship as signed, static XCFrameworks under the
[MOQOM SDK Binary License](LICENSE-BINARY.md), which allows use with MOQOM Cloud
or with a self-hosted relay that is registered with your MOQOM account.

## Install

In Xcode, **File → Add Package Dependencies…** and enter
`https://github.com/moqom-cloud/moqom-swift`, or in `Package.swift`:

```swift
.package(url: "https://github.com/moqom-cloud/moqom-swift", from: "0.1.0")

// in your target
.product(name: "MoqomKit", package: "moqom-swift")
```

| Product | Modules | Use it for |
| --- | --- | --- |
| `MoqomKit` | `MoqomCore`, `MoqomWire`, `MoqomKit`, `MoqomUI` | Apps |
| `MoqomLoopback` | the above plus `MoqomLoopback` | An in-memory relay for previews, tests and offline demos |
| `MoqomWire` | `MoqomCore`, `MoqomWire` | The MoQ Transport message codec on its own |

Requirements: Xcode 26 (Swift 6.2) and a deployment target of 26 on every
platform.

## Quickstart

Your backend mints a session token for the device with your MOQOM API key (see
[moqom-go](https://github.com/moqom-cloud/moqom-go) or
[moqom-rust](https://github.com/moqom-cloud/moqom-rust)); the app connects,
joins, and goes live. Below, `myBackend.moqomToken` stands for your own call to
your server, returning the SDK's `IssuedToken`; `tenantID` and `relayHost` come
from your MOQOM account.

```swift
import MoqomCore
import MoqomKit

let deviceKey = try DeviceKey.installed()
let issued: IssuedToken = try await myBackend.moqomToken(room: "demo", thumbprint: deviceKey.thumbprint)

let session = MoqomSession(
    transport: MoqtTransport.network(),
    credentials: DeviceCredentials(
        identity: ParticipantIdentity(
            username: try Username(issued.username),
            device: try DeviceID(thumbprint: deviceKey.thumbprint)
        ),
        token: issued.token,
        deviceKey: deviceKey,
        expiresAt: issued.expiresAt,
        renew: { try await myBackend.moqomToken(room: "demo", thumbprint: deviceKey.thumbprint) }
    ),
    tenant: TenantID(tenantID)
)
try await session.connect(to: RelayEndpoint(host: relayHost))
let room = try await session.join(room: RoomID("demo"))

let camera = try CameraSource(format: CaptureFormat(size: PixelSize(width: 1280, height: 720), frameRate: 30))
camera.start()
try await room.startBroadcast(from: camera).start()
```

Showing the room. The grid reports each tile's size to the room's
`LayoutObserver`, so you do not have to:

```swift
import MoqomUI

MoqomGalleryView(gallery: gallery, reportingTo: layout) { slot in
    ParticipantTile(slot: slot)
}
```

The full walkthrough, including the backend half, is the
[quickstart](https://moqom.dev/getting-started/quickstart/).

## The sample app

`Samples/MoqomRoom` is an iOS app built with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd Samples/MoqomRoom
cp Local.xcconfig.example Local.xcconfig   # optional: Team ID, relay host
xcodegen generate && open MoqomRoom.xcodeproj
```

With no relay configured it runs on the in-memory loopback relay, which needs no
account and no network. See [Samples/MoqomRoom/README.md](Samples/MoqomRoom/README.md).

## Developing the shell

`swift build` and `swift test` resolve the core from the release assets named in
`Package.swift`. Maintainers with access to the core sources can build the
binaries locally and use them instead:

```sh
LOCAL_XCFRAMEWORKS=$PWD/Frameworks Scripts/build-xcframeworks.sh
swift build      # uses ./Frameworks automatically when it exists
```

## Security

Report vulnerabilities to [security@moqom.cloud](mailto:security@moqom.cloud),
not in a public issue. See [SECURITY.md](SECURITY.md).

## Licence

The source in this repository is licensed under the [Apache License 2.0](LICENSE).
The prebuilt core XCFrameworks are licensed under the
[MOQOM SDK Binary License](LICENSE-BINARY.md). See [NOTICE](NOTICE) for
trademarks and third-party notices.

"MOQOM" is a trademark of Elliott Wave LLC.
