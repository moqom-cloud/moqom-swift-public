# Contributing

Thanks for wanting to help. This repository is the Apache-2.0 part of the MOQOM
Apple SDK, maintained by Elliott Wave LLC. Issues and pull requests are welcome.

## What can be changed here

The package manifest, the SwiftUI components in `Sources/MoqomUI`, the sample
app, the tests and the documentation. The core modules (`MoqomCore`,
`MoqomWire`, `MoqomKit`, `MoqomLoopback`) are prebuilt binaries; bugs in them
are welcome as issues, with a reproduction against the public API.

## Before you open a pull request

1. **Sign the CLA.** Your first pull request asks you to sign the
   [Copyright Assignment Agreement](.github/CLA.md) by leaving a comment. It
   assigns the copyright in your contribution to Elliott Wave LLC and licenses
   it back to you for any use.
2. **Open an issue first for anything bigger than a bug fix**, so nobody spends
   a weekend on a change that conflicts with work in progress.
3. **Keep the public API stable.** Additions are easy; renames and removals need
   a deprecation period and a note in the release notes.
4. **No relay addresses, project IDs, tokens or keys** in code, tests or samples.

## Building and testing

```sh
swift build
swift test
```

This needs Xcode 26 (Swift 6.2) with the 26 SDKs. The package downloads the
core frameworks from the release named in `Package.swift`. The tests use no
network beyond that and no account.

For the sample app, see [Samples/MoqomRoom/README.md](Samples/MoqomRoom/README.md).

## Security

Do not open a public issue for a vulnerability. Email security@moqom.cloud;
see [SECURITY.md](SECURITY.md).

## Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
