import Foundation

struct SavedDevice: Codable, Identifiable, Hashable {
    let host: String
    let port: UInt16
    var id: String { "\(host):\(port)" }
}

class DeviceStore: ObservableObject {
    @Published private(set) var devices: [SavedDevice] = []
    private static let key = "soy.mdempsky.AndroidScreenshot.savedDevices"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([SavedDevice].self, from: data) {
            devices = decoded
        }
    }

    func add(host: String, port: UInt16) {
        let device = SavedDevice(host: host, port: port)
        guard !devices.contains(where: { $0.id == device.id }) else { return }
        devices.append(device)
        persist()
    }

    func remove(_ device: SavedDevice) {
        devices.removeAll { $0.id == device.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
