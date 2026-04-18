import Foundation
import ADB

Task {
    do {
        try await run()
        exit(0)
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
dispatchMain()

func run() async throws {
    var args = CommandLine.arguments.dropFirst()

    guard let target = args.popFirst() else {
        fputs("Usage: swift-adb <host[:port]> [install <apk>] [shell <cmd…>]\n", stderr)
        exit(1)
    }

    let (host, port) = parseHostPort(target)

    fputs("Connecting to \(host):\(port)…\n", stderr)
    let conn = ADBConnection(authProvider: FileSystemAuth())
    let deviceName = try await conn.connect(host: host, port: port) { progress in
        switch progress {
        case .authenticating:
            fputs("Authenticating…\n", stderr)
        case .needsKeyApproval(let fp):
            fputs("Key fingerprint: \(fp)\nAccept on device to continue.\n", stderr)
        }
    }
    fputs("Connected\(deviceName.isEmpty ? "" : " to \(deviceName)").\n", stderr)

    let installer = APKInstaller(connection: conn)

    guard let subcommand = args.popFirst() else {
        let info = try await installer.shell("getprop ro.product.model && getprop ro.build.version.release")
        print(info.trimmingCharacters(in: .whitespacesAndNewlines))
        return
    }

    switch subcommand {
    case "install":
        guard let apkPath = args.popFirst() else {
            fputs("Usage: swift-adb <host> install <apk-path>\n", stderr); exit(1)
        }
        try await installer.install(apkURL: URL(fileURLWithPath: apkPath)) { msg in
            fputs("\(msg)\n", stderr)
        }

    case "wake":
        _ = try await installer.shell("input keyevent 224")

    case "screencap":
        let png = try await installer.screencap()
        FileHandle.standardOutput.write(png)

    case "shell":
        let cmd = args.joined(separator: " ")
        guard !cmd.isEmpty else { fputs("Usage: swift-adb <host> shell <command>\n", stderr); exit(1) }
        print(try await installer.shell(cmd), terminator: "")

    default:
        fputs("Unknown subcommand: \(subcommand)\n", stderr)
        exit(1)
    }

    await conn.disconnect()
}

func parseHostPort(_ s: String) -> (String, UInt16) {
    if let colon = s.lastIndex(of: ":"), let port = UInt16(s[s.index(after: colon)...]) {
        return (String(s[..<colon]), port)
    }
    return (s, 5555)
}
