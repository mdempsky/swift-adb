import Foundation

public final class ADBStream: @unchecked Sendable {
    public let localId: UInt32
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

    public func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock { openCont = cont }
        }
    }

    public func read() async throws -> Data {
        if let immediate = lock.withLock({ () -> Data? in
            guard buffer.isEmpty else { defer { buffer = Data() }; return buffer }
            return nil
        }) { return immediate }

        if lock.withLock({ closed }) { throw ADBError.streamClosed }

        return try await withCheckedThrowingContinuation { cont in
            lock.withLock {
                if !buffer.isEmpty {
                    let d = buffer; buffer = Data(); cont.resume(returning: d)
                } else if closed {
                    cont.resume(throwing: ADBError.streamClosed)
                } else {
                    dataCont = cont
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        guard let conn = connection else { throw ADBError.streamClosed }
        let remoteId = lock.withLock { self.remoteId }
        try await conn.send(ADBMessage(command: .WRTE, arg0: localId, arg1: remoteId, data: data))
    }

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
