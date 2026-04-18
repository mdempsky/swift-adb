import Foundation

struct SavedDevice: Codable, Identifiable, Hashable {
    let host: String
    let port: UInt16
    var id: String { "\(host):\(port)" }
}

class SavedDevices: ObservableObject {
    @Published private(set) var devices: [SavedDevice] = []
    private static let key = "soy.mdempsky.SwiftADB.savedDevices"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([SavedDevice].self, from: data) {
            devices = decoded
        }
    }

    func record(host: String, port: UInt16) {
        let device = SavedDevice(host: host, port: port)
        devices.removeAll { $0.id == device.id }
        devices.insert(device, at: 0)
        if devices.count > 5 { devices = Array(devices.prefix(5)) }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
