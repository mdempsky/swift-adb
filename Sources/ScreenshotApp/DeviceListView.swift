import SwiftUI

struct DeviceListView: View {
    @EnvironmentObject var deviceStore: DeviceStore
    @Binding var selectedDevice: SavedDevice?
    @State private var showAddDevice = false

    var body: some View {
        List(deviceStore.devices, selection: $selectedDevice) { device in
            NavigationLink(value: device) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.host)
                    if device.port != 5555 {
                        Text("Port \(device.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .contextMenu {
                Button(role: .destructive) {
                    if selectedDevice == device { selectedDevice = nil }
                    deviceStore.remove(device)
                } label: {
                    Label("Remove Device", systemImage: "trash")
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if deviceStore.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No Devices")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Click + to add an Android device")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem {
                Button { showAddDevice = true } label: {
                    Image(systemName: "plus")
                }
                .help("Add Android Device")
            }
        }
        .sheet(isPresented: $showAddDevice) {
            AddDeviceSheet()
                .environmentObject(deviceStore)
        }
    }
}
