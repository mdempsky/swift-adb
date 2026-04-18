import Foundation

/// High-level ADB operations over an established connection.
public struct APKInstaller {
    private let connection: ADBConnection

    public init(connection: ADBConnection) {
        self.connection = connection
    }

    // MARK: - Install

    public func install(
        apkURL: URL,
        progress: @Sendable @escaping (String) -> Void = { _ in }
    ) async throws {
        let data = try Data(contentsOf: apkURL)
        let remote = "/data/local/tmp/swift-adb-install.apk"

        progress("Pushing \(apkURL.lastPathComponent) (\(data.count / 1024) KB)…")
        try await push(data: data, remotePath: remote, progress: progress)

        progress("Installing…")
        let result = try await shell("pm install -r \(remote)")
        progress(result.trimmingCharacters(in: .whitespacesAndNewlines))

        progress("Cleaning up…")
        _ = try? await shell("rm \(remote)")
    }

    // MARK: - Shell

    public func shell(_ command: String) async throws -> String {
        let stream = try await connection.openStream(destination: "shell:\(command)")
        var output = ""
        do {
            while true { output += String(bytes: try await stream.read(), encoding: .utf8) ?? "" }
        } catch ADBError.streamClosed {}
        return output
    }

    // MARK: - Screencap

    public func screencap() async throws -> Data {
        let stream = try await connection.openStream(destination: "shell:screencap -p")
        var data = Data()
        do { while true { data.append(try await stream.read()) } }
        catch ADBError.streamClosed {}
        return data
    }

    // MARK: - SYNC push

    private func push(data: Data, remotePath: String, progress: @Sendable (String) -> Void) async throws {
        let stream = try await connection.openStream(destination: "sync:")

        let spec = remotePath + ",0644"
        try await stream.write(syncPkt("SEND", UInt32(spec.utf8.count)) + Data(spec.utf8))

        let chunkSize = 65536
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            try await stream.write(syncPkt("DATA", UInt32(end - offset)) + data[offset..<end])
            offset = end
            progress("Pushed \(offset * 100 / data.count)%…")
        }

        try await stream.write(syncPkt("DONE", UInt32(Date().timeIntervalSince1970)))

        let resp = try await stream.read()
        if resp.count >= 4, String(bytes: resp.prefix(4), encoding: .utf8) == "FAIL" {
            let msg = resp.count > 8 ? String(bytes: resp.dropFirst(8), encoding: .utf8) ?? "?" : "?"
            throw ADBError.protocolError("SYNC FAIL: \(msg)")
        }
    }

    private func syncPkt(_ id: String, _ length: UInt32) -> Data {
        var d = Data(id.utf8)
        var le = length.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        return d
    }
}
