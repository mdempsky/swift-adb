import Foundation

public enum ADBError: Error, LocalizedError, Sendable {
    case connectionFailed(String)
    case authFailed
    case protocolError(String)
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
