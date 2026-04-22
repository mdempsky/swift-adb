import SwiftUI

struct ContentView: View {
    @EnvironmentObject var deviceStore: DeviceStore
    @State private var selectedDevice: SavedDevice?
    @StateObject private var connection = ConnectionModel()

    var body: some View {
        NavigationSplitView {
            DeviceListView(selectedDevice: $selectedDevice)
                .environmentObject(deviceStore)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let device = selectedDevice {
                DeviceDetailView(device: device, connection: connection)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "iphone")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a Device")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Choose a device from the sidebar, or click + to add one.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: selectedDevice, perform: { newDevice in
            connection.disconnect()
            if let device = newDevice {
                Task { await connection.connect(to: device) }
            }
        })
    }
}
