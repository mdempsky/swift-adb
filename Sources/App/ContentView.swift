import SwiftUI

struct ContentView: View {
    @StateObject private var connection = ADBConnection()
    @StateObject private var discovery = DeviceDiscovery()
    @StateObject private var saved = SavedDevices()
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            DevicePickerView(connection: connection, discovery: discovery, saved: saved)
                .navigationDestination(for: String.self) { _ in
                    DeviceView(connection: connection)
                }
        }
        .overlay {
            if let fp = connection.rsaFingerprint {
                ADBAuthPromptView(fingerprint: fp) {
                    connection.cancelAuth()
                }
            }
        }
        .onReceive(connection.$state) { state in
            switch state {
            case .connected:
                if path.isEmpty { path = ["device"] }
            case .connecting, .authenticating:
                break
            default:
                if !path.isEmpty { path = [] }
            }
        }
    }
}
