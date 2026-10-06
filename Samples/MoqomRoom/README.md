# MoqomRoom

An iOS sample app built on MoqomKit: join a room, publish camera or a synthetic
test pattern, watch everyone else in a `MoqomGalleryView`, and keep watching in
Picture in Picture or from a Live Activity.

## Run it

Needs Xcode 26 with the iOS 26 SDK, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd Samples/MoqomRoom
cp Local.xcconfig.example Local.xcconfig   # optional, see below
xcodegen generate
open MoqomRoom.xcodeproj
```

The project depends on the package at the repository root, so it builds
against the same `MoqomKit` you would get from Swift Package Manager.

## Choosing a relay

With no relay configured the app runs on `MoqomLoopback`, an in-memory relay
inside the app. It needs no account and no network, which makes it the quickest
way to see the UI work; two devices on the loopback do not see each other.

To use a real relay, set it in `Local.xcconfig`:

```
MOQOM_RELAY_HOST = relay.example.com
MOQOM_RELAY_PORT = 443
```

or pass launch arguments (Xcode: **Product → Scheme → Edit Scheme → Arguments**):

| Argument | Meaning |
| --- | --- |
| `--relay-host HOST` / `--relay-port PORT` | Relay to dial |
| `--relay-cert-hash HASH` | Pin a relay certificate (base64 SHA-256); omit to use system trust |
| `--relay-token TOKEN` | A session token minted by your backend |
| `--join-host HOST` / `--join-port PORT` | Token service (default `api.moqom.cloud:443`) |
| `--join-credential VALUE` | A device credential for the token service |
| `--loopback` | Force the in-memory relay |
| `--username NAME`, `--room NAME` | Skip typing them on the join screen |

A `moqom://join?relay=…` link (for example from a QR code) fills the same
fields; see `Invitation.swift`.

## Tokens

A relay that verifies tokens admits a session without one but lets it publish
nothing. Tokens are minted by your backend with a MOQOM API key, using
[moqom-go](https://github.com/moqom-cloud/moqom-go) or
[moqom-rust](https://github.com/moqom-cloud/moqom-rust); never put an API key in
an app. The guide is at [moqom.dev](https://moqom.dev/getting-started/quickstart/).

## Where to look

| File | Shows |
| --- | --- |
| `RoomModel.swift` | Joining, publishing, subscribing; the app's bridge to `RoomSession` |
| `RoomScreen.swift` | `MoqomGalleryView` and the room UI |
| `RemoteVideoView.swift` | Drawing a participant's video |
| `RelayConfiguration.swift` | Relay, token and launch-argument handling |
| `Credential.swift` | Storing tokens and credentials in the Keychain |
| `PictureInPicture.swift` | Picture in Picture |
| `MoqomRoomWidgets/` | The Live Activity |
