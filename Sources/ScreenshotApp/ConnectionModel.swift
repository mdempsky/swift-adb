import SwiftUI
import ADB

@MainActor
class ConnectionModel: ObservableObject {
    enum State {
        case disconnected, connecting, authenticating, needsKeyApproval, connected, takingScreenshot
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var screenshots: [NSImage] = []
    @Published private(set) var rsaFingerprint: String?
    @Published private(set) var deviceName: String?
    @Published private(set) var errorMessage: String?

    var isConnected: Bool { state == .connected || state == .takingScreenshot }
    var isBusy: Bool { state == .takingScreenshot }

    private var conn: ADB.ADBConnection?
    private var keyApprovalWasShown = false

    func connect(to device: SavedDevice) async {
        disconnect()
        keyApprovalWasShown = false
        await attemptConnect(to: device, allowRetry: true)
    }

    func disconnect() {
        if let c = conn { Task { await c.disconnect() } }
        conn = nil
        state = .disconnected
        screenshots = []
        rsaFingerprint = nil
        deviceName = nil
        errorMessage = nil
        keyApprovalWasShown = false
    }

    func takeScreenshot() async {
        guard let conn, state == .connected else { return }
        state = .takingScreenshot
        errorMessage = nil
        do {
            let installer = APKInstaller(connection: conn)
            let data = try await installer.screencap()
            if let image = NSImage(data: data) {
                screenshots.append(image)
            }
            state = .connected
        } catch {
            errorMessage = error.localizedDescription
            state = .connected
        }
    }

    // MARK: - Private

    private func attemptConnect(to device: SavedDevice, allowRetry: Bool) async {
        let newConn = ADB.ADBConnection(authProvider: KeychainAuth.shared)
        conn = newConn
        state = .connecting
        errorMessage = nil

        do {
            let name = try await newConn.connect(host: device.host, port: device.port) { [weak self] progress in
                Task { @MainActor [weak self] in
                    switch progress {
                    case .authenticating:
                        self?.state = .authenticating
                    case .needsKeyApproval(let fp):
                        self?.rsaFingerprint = fp
                        self?.state = .needsKeyApproval
                        self?.keyApprovalWasShown = true
                    }
                }
            }
            rsaFingerprint = nil
            deviceName = name.isEmpty ? nil : name
            state = .connected
        } catch {
            conn = nil
            if keyApprovalWasShown && allowRetry {
                // Android sometimes resets the connection after accepting a new key. Retry once.
                state = .connecting
                keyApprovalWasShown = false
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard state == .connecting else { return }
                await attemptConnect(to: device, allowRetry: false)
            } else {
                state = .disconnected
                errorMessage = error.localizedDescription
            }
        }
    }
}
