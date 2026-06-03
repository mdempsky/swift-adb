import Foundation

/// High-level ADB operations over an established ``ADBConnection``.
///
/// `APKInstaller` wraps common ADB workflows — shell commands, file pushes,
/// APK installation, and screen capture — behind a simple async API. Construct
/// one with an already-connected ``ADBConnection`` and call its methods freely;
/// each call opens its own stream and closes it when done.
///
/// ```swift
/// let installer = APKInstaller(connection: conn)
///
/// // Run a shell command
/// let model = try await installer.shell("getprop ro.product.model")
///
/// // Install an APK
/// try await installer.install(apkURL: URL(fileURLWithPath: "MyApp.apk")) { message in
///     print(message)
/// }
/// ```
public struct APKInstaller {
    private let connection: ADBConnection

    /// Creates an installer backed by the given connection.
    ///
    /// - Parameter connection: An authenticated, connected ``ADBConnection``.
    public init(connection: ADBConnection) {
        self.connection = connection
    }

    // MARK: - Install

    /// Installs an APK on the device.
    ///
    /// Pushes the APK to `/data/local/tmp/` on the device, runs
    /// `pm install -r` to install it, and removes the temporary file.
    ///
    /// - Parameters:
    ///   - apkURL: The local file URL of the APK to install.
    ///   - progress: A closure called with human-readable status messages
    ///     as the operation proceeds (e.g., `"Pushing MyApp.apk (4096 KB)…"`,
    ///     `"Installing…"`, `"Success"`). Called on an arbitrary thread.
    /// - Throws: An ``ADBError`` if the connection fails, or any `Error` thrown
    ///   by reading the file or by `pm install` returning a failure status.
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

    /// Runs a shell command on the device and returns its combined output.
    ///
    /// Opens a `shell:` stream, reads until the stream closes, and returns all
    /// output as a single string. This is equivalent to `adb shell <command>`.
    ///
    /// - Parameter command: The shell command to execute on the device.
    /// - Returns: The complete stdout+stderr output of the command.
    /// - Throws: An ``ADBError`` if the connection fails or the stream is closed
    ///   unexpectedly.
    public func shell(_ command: String) async throws -> String {
        let stream = try await connection.openStream(destination: "shell:\(command)")
        var output = ""
        do {
            while true { output += String(bytes: try await stream.read(), encoding: .utf8) ?? "" }
        } catch ADBError.streamClosed {}
        return output
    }

    // MARK: - Screencap

    /// Captures a PNG screenshot from the device.
    ///
    /// Runs `screencap -p` on the device and returns the raw PNG bytes.
    /// Write the result to a file or pass it to `UIImage` / `NSImage` directly.
    ///
    /// - Returns: A `Data` value containing a PNG-encoded screenshot.
    /// - Throws: An ``ADBError`` if the connection fails or the stream is closed
    ///   unexpectedly.
    public func screencap() async throws -> Data {
        let stream = try await connection.openStream(destination: "shell:screencap -p")
        var data = Data()
        do { while true { data.append(try await stream.read()) } }
        catch ADBError.streamClosed {}
        return data
    }

    // MARK: - Privileged setup

    /// Restarts `adbd` as root.
    ///
    /// Equivalent to `adb root`. When the output contains `"restarting adbd as root"`,
    /// the daemon is restarting and the current connection becomes invalid; call
    /// ``ADBConnection/reconnect()`` before issuing further commands.
    ///
    /// - Returns: The trimmed output from the `root:` service, e.g.
    ///   `"restarting adbd as root"` or `"adbd is already running as root"`.
    /// - Throws: An ``ADBError`` if the stream cannot be opened.
    public func root() async throws -> String {
        let stream = try await connection.openStream(destination: "root:")
        var output = ""
        do { while true { output += String(bytes: try await stream.read(), encoding: .utf8) ?? "" } }
        catch ADBError.streamClosed {}
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Disables dm-verity on the device.
    ///
    /// Equivalent to `adb disable-verity`. Requires `adbd` to be running as root.
    /// When verity was active, a reboot is needed before the change takes effect;
    /// the output contains `"Now reboot your device"` in that case.
    ///
    /// - Returns: The trimmed output from the `disable-verity:` service.
    /// - Throws: An ``ADBError`` if the stream cannot be opened.
    public func disableVerity() async throws -> String {
        let stream = try await connection.openStream(destination: "disable-verity:")
        var output = ""
        do { while true { output += String(bytes: try await stream.read(), encoding: .utf8) ?? "" } }
        catch ADBError.streamClosed {}
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remounts `/system` (and other overlayfs partitions) as read-write.
    ///
    /// Equivalent to `adb remount`. Requires `adbd` to be running as root and
    /// dm-verity to be disabled. The output contains `"remount succeeded"` on success.
    ///
    /// - Returns: The trimmed output from the `remount:` service.
    /// - Throws: An ``ADBError`` if the stream cannot be opened.
    public func remount() async throws -> String {
        let stream = try await connection.openStream(destination: "remount:")
        var output = ""
        do { while true { output += String(bytes: try await stream.read(), encoding: .utf8) ?? "" } }
        catch ADBError.streamClosed {}
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reboots the device.
    ///
    /// Equivalent to `adb reboot [reason]`. The connection drops as the device restarts.
    /// Call ``ADBConnection/reconnect()`` afterwards to wait for the device to come back up.
    ///
    /// - Parameter reason: An optional reboot target such as `"bootloader"` or `"recovery"`.
    ///   Omit or pass an empty string for a normal reboot.
    /// - Throws: An ``ADBError`` if the stream cannot be opened.
    public func reboot(reason: String = "") async throws {
        let destination = reason.isEmpty ? "reboot:" : "reboot:\(reason)"
        let stream = try await connection.openStream(destination: destination)
        do { while true { _ = try await stream.read() } }
        catch ADBError.streamClosed {}
    }

    /// Installs an APK as a privileged system app.
    ///
    /// Performs the full bootstrap sequence for installing an APK under
    /// `/system/priv-app/`, which grants it the `INSTALL_PACKAGES` permission
    /// needed to act as an over-the-air updater:
    ///
    /// 1. Gains root (`root:`), reconnects.
    /// 2. Remounts `/system` read-write. If remount fails (verity is active),
    ///    disables verity, reboots, reconnects, gains root again, reconnects,
    ///    then remounts.
    /// 3. Creates the priv-app directory and pushes the APK via sync.
    /// 4. Pushes the permissions XML to `/system/etc/permissions/`.
    /// 5. Reboots so Android rescans `/system/priv-app/`.
    ///
    /// The connection is invalid after this method returns (the final reboot drops
    /// it). Call ``ADBConnection/reconnect()`` if you need to issue further commands.
    ///
    /// - Parameters:
    ///   - apkURL: The local file URL of the APK to install.
    ///   - packageName: The Android package name, e.g. `"com.tonal.kronos"`. Used to
    ///     derive the install path `/system/priv-app/<packageName>/<packageName>.apk`.
    ///   - permissionsXML: The full content of the `privapp-permissions` XML file to
    ///     write to `/system/etc/permissions/privapp-permissions-<packageName>.xml`.
    ///   - progress: A closure called with human-readable status messages. Called on an
    ///     arbitrary thread.
    /// - Throws: An ``ADBError`` if any step fails.
    public func installPrivApp(
        apkURL: URL,
        packageName: String,
        permissionsXML: String,
        progress: @Sendable @escaping (String) -> Void = { _ in }
    ) async throws {
        let apkData = try Data(contentsOf: apkURL)
        let apkRemote = "/system/priv-app/\(packageName)/\(packageName).apk"
        let permRemote = "/system/etc/permissions/privapp-permissions-\(packageName).xml"
        let permData = Data(permissionsXML.utf8)

        progress("Gaining root…")
        _ = try await root()
        progress("Reconnecting…")
        try await connection.reconnect()

        progress("Remounting system…")
        let remountResult = try await remount()
        if !remountResult.lowercased().contains("succeeded") {
            progress("Disabling verified boot…")
            _ = try await disableVerity()
            progress("Rebooting for verity change…")
            try await reboot()
            progress("Waiting for device…")
            try await connection.reconnect()
            progress("Gaining root…")
            _ = try await root()
            progress("Reconnecting…")
            try await connection.reconnect()
            progress("Remounting system…")
            _ = try await remount()
        }

        _ = try? await shell("mkdir -p /system/priv-app/\(packageName)")

        progress("Pushing \(apkURL.lastPathComponent) (\(apkData.count / 1024) KB)…")
        try await push(data: apkData, remotePath: apkRemote, progress: progress)

        progress("Pushing permissions…")
        try await push(data: permData, remotePath: permRemote, progress: progress)

        progress("Rebooting to apply…")
        try await reboot()
        progress("Rebooting. Wait for device to come back online.")
    }

    // MARK: - SYNC push

    /// Pushes raw data to a path on the device via the ADB sync protocol.
    ///
    /// - Parameters:
    ///   - data: The file contents to write.
    ///   - remotePath: The absolute path on the device to write to.
    ///   - progress: A closure called with human-readable progress messages.
    /// - Throws: An ``ADBError`` if the connection fails or the device reports
    ///   a sync failure.
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
