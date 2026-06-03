import Foundation

/// A bidirectional data stream multiplexed over an ADB connection.
///
/// Streams are opened by ``ADBConnection/openStream(destination:)`` and correspond
/// to a single ADB logical channel (identified by a local/remote ID pair). Each
/// stream targets a named service on the device, such as `"shell:ls"` or `"sync:"`.
///
/// ``read()`` and ``write(_:)`` are the primary I/O operations. Both suspend the
/// calling task rather than blocking a thread. A stream is fully closed — on both
/// ends — once ``close()`` has been called or the remote peer sends a CLSE message,
/// after which ``read()`` throws ``ADBError/streamClosed``.
///
/// > Important: Concurrent calls to ``read()`` or ``waitForOpen()`` on the same
/// > stream are not supported and will trap.
public final class ADBStream: @unchecked Sendable {

    /// The local stream ID assigned by the connection, used in outgoing ADB messages.
    public let localId: UInt32

    /// The remote stream ID assigned by the device, used in outgoing ADB messages.
    /// Zero until the stream is opened (i.e., until ``waitForOpen()`` returns).
    public private(set) var remoteId: UInt32 = 0

    weak var connection: ADBConnection?

    private let lock = NSLock()
    private var openCont: CheckedContinuation<Void, Error>?
    private var dataCont: CheckedContinuation<Data, Error>?
    private var buffer = Data()
    private var closed = false

    init(localId: UInt32, connection: ADBConnection) {
        self.localId = localId
        self.connection = connection
    }

    /// Suspends until the device sends an OKAY message acknowledging the stream.
    ///
    /// Call this once immediately after the stream is created, before calling
    /// ``read()`` or ``write(_:)``. It resolves when the device confirms the
    /// service name is valid and the stream is ready for I/O.
    ///
    /// - Throws: ``ADBError/streamClosed`` if the connection is lost before the
    ///   device responds.
    public func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock {
                precondition(openCont == nil, "concurrent waitForOpen() calls not supported")
                openCont = cont
            }
        }
    }

    /// Returns the next available chunk of data from the stream.
    ///
    /// If data has already arrived and is buffered, it is returned immediately
    /// without suspending. Otherwise the calling task suspends until the device
    /// sends a WRTE message on this stream.
    ///
    /// ADB delivers data in arbitrarily sized chunks; callers are responsible for
    /// reassembling framing if the underlying service protocol requires it.
    ///
    /// - Returns: A non-empty `Data` value containing the next received chunk.
    /// - Throws: ``ADBError/streamClosed`` if the stream has been closed by either
    ///   end before data arrives.
    public func read() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock {
                if !buffer.isEmpty {
                    defer { buffer = Data() }
                    cont.resume(returning: buffer)
                } else if closed {
                    cont.resume(throwing: ADBError.streamClosed)
                } else {
                    precondition(dataCont == nil, "concurrent read() calls not supported")
                    dataCont = cont
                }
            }
        }
    }

    /// Sends data to the device as a WRTE message on this stream.
    ///
    /// - Parameter data: The bytes to send. Must not be empty.
    /// - Throws: ``ADBError/streamClosed`` if the stream has already been closed.
    public func write(_ data: Data) async throws {
        guard let conn = connection else { throw ADBError.streamClosed }
        let remoteId = lock.withLock { self.remoteId }
        try await conn.send(ADBMessage(command: .WRTE, arg0: localId, arg1: remoteId, data: data))
    }

    /// Closes the stream by sending a CLSE message to the device.
    ///
    /// After this returns, the stream is removed from the connection and further
    /// calls to ``read()`` or ``write(_:)`` will throw ``ADBError/streamClosed``.
    /// Calling ``close()`` on an already-closed stream is a no-op.
    public func close() async throws {
        guard let conn = connection else { return }
        try await conn.closeStream(self)
    }

    func receiveOkay(remoteId: UInt32) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            self.remoteId = remoteId; defer { openCont = nil }; return openCont
        }
        cont?.resume()
    }

    func receiveData(_ data: Data) {
        let cont = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            if let c = dataCont { dataCont = nil; return c }
            buffer.append(data); return nil
        }
        cont?.resume(returning: data)
    }

    func receiveClosed() {
        let (oc, dc) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, CheckedContinuation<Data, Error>?) in
            closed = true; defer { openCont = nil; dataCont = nil }; return (openCont, dataCont)
        }
        oc?.resume(throwing: ADBError.streamClosed)
        dc?.resume(throwing: ADBError.streamClosed)
    }
}
