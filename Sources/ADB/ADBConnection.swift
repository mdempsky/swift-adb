import Foundation
import Network

public actor ADBConnection {

    public enum ConnectProgress: Sendable {
        case authenticating
        case needsKeyApproval(fingerprint: String)
    }

    private let authProvider: any ADBAuthProvider
    private var conn: NWConnection?
    private var pendingConnect: CheckedContinuation<Void, Error>?
    private var streams: [UInt32: ADBStream] = [:]
    private var nextLocalId: UInt32 = 1

    public init(authProvider: any ADBAuthProvider) {
        self.authProvider = authProvider
    }

    // MARK: - Connect / Disconnect

    /// Connects to an ADB daemon, authenticates, and returns the device model name.
    @discardableResult
    public func connect(
        host: String,
        port: UInt16 = 5555,
        onProgress: (@Sendable (ConnectProgress) -> Void)? = nil
    ) async throws -> String {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let c = NWConnection(to: endpoint, using: .tcp)
        conn = c

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingConnect = cont
            c.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                Task { await self.handleConnectState(newState) }
            }
            c.start(queue: DispatchQueue(label: "adb.connection", qos: .userInitiated))
        }

        try await sendCNXN()
        onProgress?(.authenticating)
        let deviceName = try await doAuth(onProgress: onProgress)
        Task { await readLoop() }
        return deviceName
    }

    public func disconnect() {
        conn?.cancel()
        conn = nil
        streams.values.forEach { $0.receiveClosed() }
        streams.removeAll()
        pendingConnect = nil
    }

    // MARK: - Streams

    public func openStream(destination: String) async throws -> ADBStream {
        let localId = nextLocalId; nextLocalId += 1
        let stream = ADBStream(localId: localId, connection: self)
        streams[localId] = stream
        try await send(ADBMessage(command: .OPEN, arg0: localId, arg1: 0,
                                  data: Data(destination.utf8) + Data([0])))
        try await stream.waitForOpen()
        return stream
    }

    func closeStream(_ stream: ADBStream) async throws {
        streams.removeValue(forKey: stream.localId)
        try await send(ADBMessage(command: .CLSE, arg0: stream.localId, arg1: stream.remoteId))
    }

    // MARK: - Internal send

    func send(_ msg: ADBMessage) async throws {
        guard let c = conn else { throw ADBError.connectionFailed("not connected") }
        let data = msg.encode()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    // MARK: - Private

    private func handleConnectState(_ state: NWConnection.State) {
        guard let cont = pendingConnect else { return }
        switch state {
        case .ready:
            pendingConnect = nil; cont.resume()
        case .failed(let err):
            pendingConnect = nil; cont.resume(throwing: ADBError.connectionFailed(err.localizedDescription))
        case .cancelled:
            pendingConnect = nil; cont.resume(throwing: ADBError.connectionFailed("cancelled"))
        default:
            break
        }
    }

    private func sendCNXN() async throws {
        try await send(ADBMessage(command: .CNXN, arg0: 0x01000001, arg1: 256 * 1024,
                                  data: Data("host::swift-adb".utf8)))
    }

    private func doAuth(onProgress: (@Sendable (ConnectProgress) -> Void)? = nil) async throws -> String {
        let msg = try await readMessage()
        if msg.command == .CNXN { return parseDeviceName(msg.data) }
        guard msg.command == .AUTH, msg.arg0 == 1 else {
            throw ADBError.protocolError("expected AUTH TOKEN, got \(msg.command)")
        }

        let sig = try authProvider.sign(token: msg.data)
        try await send(ADBMessage(command: .AUTH, arg0: 2, data: sig))

        let resp = try await readMessage()
        if resp.command == .CNXN { return parseDeviceName(resp.data) }

        let fp = try authProvider.fingerprint()
        onProgress?(.needsKeyApproval(fingerprint: fp))

        let pubKey = try authProvider.publicKeyBytes()
        try await send(ADBMessage(command: .AUTH, arg0: 3, data: pubKey))

        let resp2 = try await readMessage()
        guard resp2.command == .CNXN else { throw ADBError.authFailed }
        return parseDeviceName(resp2.data)
    }

    private func parseDeviceName(_ data: Data) -> String {
        guard let str = String(data: data, encoding: .utf8) else { return "" }
        if let range = str.range(of: "ro.product.model=") {
            let tail = str[range.upperBound...]
            let model = String(tail.prefix(while: { $0 != ";" && $0 != "\0" && $0 != "\n" }))
            if !model.isEmpty { return model }
        }
        return ""
    }

    private func readLoop() async {
        do {
            while true { dispatch(try await readMessage()) }
        } catch {
            streams.values.forEach { $0.receiveClosed() }
            streams.removeAll()
        }
    }

    private func dispatch(_ msg: ADBMessage) {
        switch msg.command {
        case .OKAY:
            streams[msg.arg1]?.receiveOkay(remoteId: msg.arg0)
        case .WRTE:
            streams[msg.arg1]?.receiveData(msg.data)
            Task { try? await send(ADBMessage(command: .OKAY, arg0: msg.arg1, arg1: msg.arg0)) }
        case .CLSE:
            streams[msg.arg1]?.receiveClosed()
            streams.removeValue(forKey: msg.arg1)
        default:
            break
        }
    }

    private func readExact(_ length: Int) async throws -> Data {
        guard let c = conn else { throw ADBError.connectionFailed("not connected") }
        return try await withCheckedThrowingContinuation { cont in
            c.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, err in
                if let err { cont.resume(throwing: err); return }
                guard let data, data.count == length else {
                    cont.resume(throwing: ADBError.protocolError("short read"))
                    return
                }
                cont.resume(returning: data)
            }
        }
    }

    private func readMessage() async throws -> ADBMessage {
        let header = try await readExact(ADBMessage.headerSize)
        let bodyLen = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian }
        let body = bodyLen > 0 ? try await readExact(Int(bodyLen)) : Data()
        guard let msg = ADBMessage.decode(header: header, body: body) else {
            throw ADBError.protocolError("invalid message")
        }
        return msg
    }
}
