import SwiftUI
import Darwin

struct DevicePickerView: View {
    @ObservedObject var connection: ADBConnection
    @ObservedObject var discovery: DeviceDiscovery
    @ObservedObject var saved: SavedDevices

    @State private var manualHost = ""

    var isConnecting: Bool {
        switch connection.state {
        case .connecting, .authenticating: return true
        default: return false
        }
    }

    var connectingMessage: String {
        if case .authenticating = connection.state { return "Check your device…" }
        return "Connecting…"
    }

    var body: some View {
        List {
            if !saved.devices.isEmpty {
                Section("Recent") {
                    ForEach(saved.devices) { device in
                        Button { connect(host: device.host, port: device.port) } label: {
                            DeviceRow(name: device.host, port: device.port)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Nearby") {
                if discovery.devices.isEmpty {
                    Label("Scanning for devices…", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(discovery.devices) { device in
                        Button { connect(host: device.host, port: device.port) } label: {
                            DeviceRow(name: device.name, port: device.port)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Manual") {
                HStack {
                    TextField("IP address or hostname", text: $manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Connect") { connect(host: manualHost, port: 5555) }
                        .disabled(manualHost.isEmpty || isConnecting)
                }
                if case .error(let e) = connection.state {
                    Text(e.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("SwiftADB")
        .onAppear {
            discovery.start()
            if manualHost.isEmpty, let prefix = localNetworkPrefix() {
                manualHost = prefix
            }
        }
        .onDisappear { discovery.stop() }
        .overlay {
            if isConnecting {
                connectingOverlay
            }
        }
    }

    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text(connectingMessage)
                    .font(.headline)
                    .foregroundStyle(.white)
                Button("Cancel") {
                    connection.disconnect()
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.top, 4)
            }
            .padding(36)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func connect(host: String, port: UInt16 = 5555) {
        Task {
            do {
                try await connection.connect(host: host, port: port)
                saved.record(host: host, port: port)
            } catch {
                // connection.state becomes .error, shown in list
            }
        }
    }
}

private func localNetworkPrefix() -> String? {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0 else { return nil }
    defer { freeifaddrs(addrs) }

    var ptr = addrs
    while let ifa = ptr {
        defer { ptr = ifa.pointee.ifa_next }
        guard ifa.pointee.ifa_name != nil,
              String(cString: ifa.pointee.ifa_name).hasPrefix("en"),
              let sa = ifa.pointee.ifa_addr,
              sa.pointee.sa_family == sa_family_t(AF_INET),
              let sm = ifa.pointee.ifa_netmask else { continue }

        let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p -> String in
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = p.pointee.sin_addr
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        }
        let mask = sm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p -> String in
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = p.pointee.sin_addr
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        }

        let ipOcts = ip.split(separator: ".").compactMap { UInt8($0) }
        let mOcts = mask.split(separator: ".").compactMap { UInt8($0) }
        guard ipOcts.count == 4, mOcts.count == 4 else { continue }
        guard !(ipOcts[0] == 169 && ipOcts[1] == 254) else { continue } // skip link-local

        var prefix = ""
        for i in 0..<4 {
            guard mOcts[i] == 255 else { break }
            prefix += "\(ipOcts[i])."
        }
        if !prefix.isEmpty { return prefix }
    }
    return nil
}

private struct DeviceRow: View {
    let name: String
    let port: UInt16

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "candybarphone")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).bold()
                if port != 5555 {
                    Text("Port \(port)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}
