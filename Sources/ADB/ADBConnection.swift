import Foundation
import Network

/// An active connection to an ADB daemon running on an Android device.
///
/// `ADBConnection` manages a TCP socket to `adbd`, performs the RSA authentication
/// handshake, and multiplexes multiple ``ADBStream`` instances over the single
/// connection. It is implemented as a Swift actor so all internal state is
/// automatically protected from data races.
///
/// ## Lifecycle
///
/// 1. Create a connection with an ``ADBAuthProvider`` that supplies your RSA key.
/// 2. Call ``connect(host:port:onProgress:)`` to establish the TCP connection and
///    complete authentication. On the first connection from a new key, the device
///    shows an "Allow USB debugging?" dialog; ``ConnectProgress/needsKeyApproval(fingerprint:)``
///    is delivered so you can display the fingerprint to the user.
/// 3. Open service streams with ``openStream(destination:)``.
/// 4. Call ``disconnect()`` when done, or if an error occurs.
///
/// ## Example
///
/// ```swift
/// let conn = ADBConnection(authProvider: myAuth)
/// try await conn.connect(host: "10.0.0.1") { progress in
///     if case .needsKeyApproval(let fp) = progress {
///         print("Approve on device. Fingerprint: \(fp)")
///     }
/// }
/// let installer = APKInstaller(connection: conn)
/// let output = try await installer.shell("getprop ro.product.model")
/// ```
public actor ADBConnection {

    /// Progress events delivered during ``connect(host:port:onProgress:)``.
    public enum ConnectProgress: Sendable {
        /// The connection is established and authentication is in progress.
        case authenticating
        /// The host's public key is not yet trusted by the device.
        ///
        /// The associated fingerprint matches the one displayed in the
        /// "Allow USB debugging?" dialog on the device screen. Show it to the
        /// user so they can verify they're approving the right host.
        case needsKeyApproval(fingerprint: String)
    }

    private let authProvider: any ADBAuthProvider
    private var conn: NWConnection?
    private var pendingConnect: CheckedContinuation<Void, Error>?
    private var streams: [UInt32: ADBStream] = [:]
    private var nextLocalId: UInt32 = 1
    private var lastHost: String?
    private var lastPort: UInt16 = 5555

    /// Creates a connection that uses the given provider for RSA authentication.
    ///
    /// - Parameter authProvider: The object that signs ADB challenge tokens and
    ///   supplies the public key bytes. The connection holds a strong reference
    ///   for its lifetime.
    public init(authProvider: any ADBAuthProvider) {
        self.authProvider = authProvider
    }

    // MARK: - Connect / Disconnect

    /// Connects to an ADB daemon and authenticates, returning the device model name.
    ///
    /// This method establishes a TCP connection to `adbd` on the given host, performs
    /// the ADB `CNXN`/`AUTH` handshake, and starts the message read loop. It suspends
    /// until authentication completes or fails.
    ///
    /// On the first connection from a new RSA key, the device shows an
    /// "Allow USB debugging?" dialog and this method suspends until the user responds.
    /// Subsequent connections using the same key succeed immediately without user
    /// interaction.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address of the device running `adbd`.
    ///   - port: The TCP port `adbd` is listening on. Defaults to `5555`,
    ///     the standard ADB-over-TCP port.
    ///   - onProgress: An optional closure called with progress events during
    ///     the handshake. Called on an arbitrary thread.
    /// - Returns: The device model name from the `CNXN` banner (e.g., `"Pixel 8"`),
    ///   or an empty string if the banner does not include one.
    /// - Throws: ``ADBError/connectionFailed(_:)`` if the TCP connection cannot be
    ///   established, or ``ADBError/authFailed`` if the device rejects the key.
    @discardableResult
    public func connect(
        host: String,
        port: UInt16 = 5555,
        onProgress: (@Sendable (ConnectProgress) -> Void)? = nil
    ) async throws -> String {
        lastHost = host
        lastPort = port
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

    /// Closes the connection and cancels all open streams.
    ///
    /// Any tasks suspended in ``ADBStream/read()`` or ``ADBStream/waitForOpen()``
    /// on streams belonging to this connection will throw ``ADBError/streamClosed``.
    /// It is safe to call this method more than once.
    public func disconnect() {
        conn?.cancel()
        conn = nil
        streams.values.forEach { $0.receiveClosed() }
        streams.removeAll()
        pendingConnect = nil
    }

    /// Disconnects and reconnects to the same host and port as the last ``connect(host:port:onProgress:)`` call.
    ///
    /// Use this after any operation that causes `adbd` to restart or the device to reboot —
    /// specifically after ``APKInstaller/root()`` and ``APKInstaller/reboot(reason:)``.
    /// Each attempt disconnects first, then retries ``connect(host:port:onProgress:)``; if the
    /// device is not yet ready, the attempt fails and the next one begins after `retryDelay`.
    ///
    /// The default values (30 retries × 3 s) give a 90-second window, enough for both a fast
    /// adbd restart (~2 s) and a full device reboot (~60 s).
    ///
    /// - Parameters:
    ///   - retries: Maximum number of connection attempts. Defaults to `30`.
    ///   - retryDelay: Pause between attempts. Defaults to `3` seconds.
    ///   - onProgress: Optional closure forwarded to ``connect(host:port:onProgress:)``.
    /// - Returns: The device model name from the `CNXN` banner.
    /// - Throws: ``ADBError/connectionFailed(_:)`` if there is no prior connection or all
    ///   attempts fail.
    @discardableResult
    public func reconnect(
        retries: Int = 30,
        retryDelay: Duration = .seconds(3),
        onProgress: (@Sendable (ConnectProgress) -> Void)? = nil
    ) async throws -> String {
        guard let host = lastHost else {
            throw ADBError.connectionFailed("no prior connection to reconnect to")
        }
        var lastError: Error = ADBError.connectionFailed("unknown")
        for attempt in 0..<retries {
            if attempt > 0 { try await Task.sleep(for: retryDelay) }
            disconnect()
            do { return try await connect(host: host, port: lastPort, onProgress: onProgress) }
            catch { lastError = error }
        }
        throw lastError
    }

    // MARK: - Streams

    /// Opens a new stream to a named service on the device.
    ///
    /// Sends an ADB `OPEN` message for the given destination and waits for the
    /// device to respond with `OKAY`. The returned stream is ready for I/O.
    ///
    /// Common destination strings:
    /// - `"shell:<command>"` — run a shell command and stream its output.
    /// - `"sync:"` — open the file sync service for push/pull operations.
    /// - `"root:"` — restart `adbd` as root (userdebug builds only).
    /// - `"remount:"` — remount `/system` read-write (userdebug builds only).
    /// - `"reboot:"` — reboot the device.
    ///
    /// - Parameter destination: The ADB service name to connect to.
    /// - Returns: An open ``ADBStream`` ready for reading and writing.
    /// - Throws: ``ADBError/streamClosed`` if the connection is lost before
    ///   the device acknowledges the stream.
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
