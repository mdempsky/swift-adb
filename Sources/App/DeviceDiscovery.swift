import Foundation
import Network

struct ADBDevice: Identifiable, Hashable {
    let id: String  // host:port
    let host: String
    let port: UInt16
    let name: String
}

@MainActor
class DeviceDiscovery: ObservableObject {
    @Published var devices: [ADBDevice] = []

    private var browser: NWBrowser?

    func start() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_adb-tls-connect._tcp", domain: "local.")
        let b = NWBrowser(for: descriptor, using: .tcp)
        browser = b

        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.update(results: results)
            }
        }
        b.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func update(results: Set<NWBrowser.Result>) {
        var found: [ADBDevice] = []
        for result in results {
            if case .service(let name, _, _, _) = result.endpoint {
                // Resolve host/port from metadata
                if case .bonjour(let record) = result.metadata,
                   let portStr = record.dictionary["port"],
                   let port = UInt16(portStr) {
                    // NWBrowser doesn't give us the resolved IP directly;
                    // use service name as host for NWConnection (it resolves via mDNS)
                    let device = ADBDevice(id: "\(name):\(port)", host: name, port: port, name: name)
                    found.append(device)
                } else {
                    // Fallback: try to use the endpoint directly
                    let device = ADBDevice(id: name, host: name, port: 5555, name: name)
                    found.append(device)
                }
            }
        }
        devices = found
    }
}
