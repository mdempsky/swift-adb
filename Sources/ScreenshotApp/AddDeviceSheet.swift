import SwiftUI

struct AddDeviceSheet: View {
    @EnvironmentObject var deviceStore: DeviceStore
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var portText = "5555"
    @FocusState private var hostFocused: Bool

    private var portNum: UInt16 { UInt16(portText) ?? 5555 }
    private var isValid: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Android Device")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("IP Address or Hostname")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("e.g. 192.168.1.100", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .focused($hostFocused)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Port")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("5555", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Device") { addDevice() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear { hostFocused = true }
    }

    private func addDevice() {
        deviceStore.add(host: host.trimmingCharacters(in: .whitespaces), port: portNum)
        dismiss()
    }
}
