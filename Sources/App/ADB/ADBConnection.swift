import Foundation
import ADB

/// Observable wrapper around ADB.ADBConnection for use with SwiftUI.
@MainActor
class ADBConnection: ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var log: [String] = []
    @Published var rsaFingerprint: String?
    @Published var deviceName: String?

    enum ConnectionState {
        case disconnected, connecting, authenticating, connected, error(Error)
    }

    let underlying = ADB.ADBConnection(authProvider: KeychainAuth.shared)
    private var conn: ADB.ADBConnection { underlying }

    func connect(host: String, port: UInt16 = 5555) async throws {
        state = .connecting
        addLog("Connecting to \(host):\(port)…")
        do {
            let name = try await conn.connect(host: host, port: port) { [weak self] progress in
                Task { @MainActor [weak self] in
                    switch progress {
                    case .authenticating:
                        self?.state = .authenticating
                        self?.addLog("Authenticating…")
                    case .needsKeyApproval(let fp):
                        self?.rsaFingerprint = fp
                    }
                }
            }
            rsaFingerprint = nil
            deviceName = name.isEmpty ? nil : name
            state = .connected
            addLog("Connected\(name.isEmpty ? "" : " to \(name)").")
            // Monitor for disconnection
            Task { [weak self] in
                // readLoop inside the actor will eventually close streams;
                // poll state by waiting for any stream open failure
                await self?.monitorConnection()
            }
        } catch {
            state = .error(error)
            addLog("Error: \(error.localizedDescription)")
            throw error
        }
    }

    func disconnect() {
        Task { await conn.disconnect() }
        state = .disconnected
        rsaFingerprint = nil
        deviceName = nil
    }

    func cancelAuth() {
        disconnect()
    }

    func openStream(destination: String) async throws -> ADB.ADBStream {
        return try await conn.openStream(destination: destination)
    }

    func addLog(_ s: String) {
        log.append(s)
    }

    // MARK: - Private

    private func monitorConnection() async {
        // Detect drops: try opening a no-op stream; if connection dies the actor's
        // readLoop closes everything and subsequent calls throw immediately.
        // We rely on ScreencastSession error propagation for now.
        _ = try? await Task.sleep(nanoseconds: UINT64_MAX) // park until cancelled
    }
}
