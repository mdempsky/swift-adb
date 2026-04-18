# swift-adb

A Swift implementation of the [ADB (Android Debug Bridge)](https://developer.android.com/tools/adb) protocol, for connecting to Android devices over TCP from macOS or iOS without requiring the Android SDK.

Includes:
- **`ADB` library** — Swift package for embedding ADB connectivity in your own app
- **`swift-adb` CLI** — command-line tool for macOS

## Requirements

- Swift 5.9+
- macOS 13+ or iOS 16+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/mdempsky/swift-adb", from: "0.1.0"),
```

Or as a local path dependency:

```swift
.package(path: "../swift-adb"),
```

Then add `"ADB"` to your target's dependencies.

### CLI (macOS)

```bash
swift build -c release
cp .build/release/swift-adb /usr/local/bin/
```

## Usage

### CLI

```bash
# Connect and print device info
swift-adb 10.0.0.1

# Install an APK
swift-adb 10.0.0.1 install MyApp.apk

# Run a shell command
swift-adb 10.0.0.1 shell getprop ro.product.model

# Wake screen
swift-adb 10.0.0.1 wake

# Capture screenshot (writes PNG to stdout)
swift-adb 10.0.0.1 screencap > screen.png
```

The default port is 5555. Specify a custom port with `host:port`.

On first connect, the device will show an authorization dialog. The CLI stores the RSA key in `~/.android/adbkey` (compatible with the official ADB tool).

### Library

```swift
import ADB

// Provide your own auth (RSA key storage)
let conn = ADBConnection(authProvider: MyAuthProvider())

let deviceName = try await conn.connect(host: "10.0.0.1") { progress in
    switch progress {
    case .authenticating:
        print("Authenticating…")
    case .needsKeyApproval(let fingerprint):
        print("Approve on device. Fingerprint: \(fingerprint)")
    }
}

// Run a shell command
let installer = APKInstaller(connection: conn)
let output = try await installer.shell("getprop ro.product.model")

// Install an APK
try await installer.install(apkURL: URL(fileURLWithPath: "MyApp.apk")) { message in
    print(message)
}

await conn.disconnect()
```

### Implementing `ADBAuthProvider`

The library delegates RSA key management to your app via the `ADBAuthProvider` protocol:

```swift
public protocol ADBAuthProvider: Sendable {
    func sign(token: Data) throws -> Data
    func publicKeyBytes() throws -> Data
    func fingerprint() throws -> String
}
```

- `sign(token:)` — sign a 20-byte SHA1 digest with your RSA-2048 private key using PKCS1v15
- `publicKeyBytes()` — return the public key in ADB wire format (use `ADBPublicKey.authData`)
- `fingerprint()` — return the MD5 fingerprint shown to the user (use `ADBPublicKey.fingerprint`)

The `ADBPublicKey` helper converts a PKCS#1 DER-encoded RSA public key to these formats.

For iOS Keychain storage, see the example in `Sources/App/ADB/KeychainAuth.swift`.

## License

Public domain — see [Unlicense](https://unlicense.org).
