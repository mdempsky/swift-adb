import Foundation

/// Errors thrown by the ADB library.
public enum ADBError: Error, LocalizedError, Sendable {

    /// The TCP connection to the ADB daemon could not be established or was lost.
    ///
    /// The associated string contains a human-readable description of the underlying
    /// network failure.
    case connectionFailed(String)

    /// The ADB RSA authentication handshake failed.
    ///
    /// This typically means the host's public key was not approved on the device.
    /// The user must accept the "Allow USB debugging?" prompt on the device screen,
    /// or the key must already be in the device's trusted keys list.
    case authFailed

    /// The device sent data that does not conform to the ADB protocol.
    ///
    /// The associated string identifies the specific violation. This error usually
    /// indicates a bug in the library or an incompatible ADB daemon version.
    case protocolError(String)

    /// An I/O operation was attempted on a stream that has already been closed.
    ///
    /// Thrown by ``ADBStream/read()``, ``ADBStream/write(_:)``, and
    /// ``ADBStream/waitForOpen()`` when the stream is closed by either end before
    /// or during the operation.
    case streamClosed

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let s): return "Connection failed: \(s)"
        case .authFailed: return "ADB authentication failed"
        case .protocolError(let s): return "Protocol error: \(s)"
        case .streamClosed: return "Stream closed"
        }
    }
}
