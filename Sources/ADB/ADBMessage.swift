import Foundation

/// The set of command codes defined by the ADB protocol wire format.
///
/// Each value is a four-byte ASCII identifier packed as a little-endian `UInt32`.
public enum ADBCommand: UInt32, Sendable {
    /// Synchronization marker (unused in normal operation).
    case SYNC = 0x434E5953
    /// Connection negotiation — exchanged during the initial handshake.
    case CNXN = 0x4E584E43
    /// Authentication — carries token challenges, signatures, and public keys.
    case AUTH = 0x48545541
    /// Open a new stream targeting a named service on the device.
    case OPEN = 0x4E45504F
    /// Acknowledgement — confirms stream open or flow-control credit.
    case OKAY = 0x59414B4F
    /// Close a stream.
    case CLSE = 0x45534C43
    /// Write data to an open stream.
    case WRTE = 0x45545257
}

/// A single message in the ADB wire protocol.
///
/// The wire encoding is a 24-byte fixed header followed by an optional data payload.
/// Use ``encode()`` to serialize and ``decode(header:body:)`` to deserialize.
public struct ADBMessage: Sendable {

    /// The command code identifying the message type.
    public var command: ADBCommand

    /// The first command-specific argument (e.g., local stream ID for OPEN/WRTE).
    public var arg0: UInt32

    /// The second command-specific argument (e.g., remote stream ID for OKAY/WRTE).
    public var arg1: UInt32

    /// The message payload. Empty for messages that carry no data.
    public var data: Data

    /// The fixed size of the wire-format header, in bytes.
    public static let headerSize = 24

    /// Creates an ADB message.
    ///
    /// - Parameters:
    ///   - command: The command code.
    ///   - arg0: The first argument. Interpretation depends on `command`.
    ///   - arg1: The second argument. Interpretation depends on `command`.
    ///   - data: The payload. Defaults to empty.
    public init(command: ADBCommand, arg0: UInt32, arg1: UInt32 = 0, data: Data = Data()) {
        self.command = command; self.arg0 = arg0; self.arg1 = arg1; self.data = data
    }

    var crc32: UInt32 { data.reduce(0) { $0 &+ UInt32($1) } }

    /// Serializes the message to its ADB wire representation.
    ///
    /// The result is a 24-byte header containing the command, arguments, payload
    /// length, CRC32, and magic value, followed immediately by the payload bytes.
    ///
    /// - Returns: The complete wire-format message.
    public func encode() -> Data {
        var buf = Data(capacity: Self.headerSize + data.count)
        func le(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { buf.append(contentsOf: $0) } }
        le(command.rawValue); le(arg0); le(arg1); le(UInt32(data.count)); le(crc32); le(command.rawValue ^ 0xFFFFFFFF)
        buf.append(data)
        return buf
    }

    /// Deserializes a message from a separately-read header and body.
    ///
    /// - Parameters:
    ///   - header: Exactly ``headerSize`` bytes from the wire.
    ///   - body: The payload bytes whose length was encoded in the header.
    /// - Returns: The decoded message, or `nil` if the header contains an
    ///   unrecognized command code.
    public static func decode(header: Data, body: Data) -> ADBMessage? {
        guard header.count == headerSize else { return nil }
        func u32(_ o: Int) -> UInt32 { header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian } }
        guard let cmd = ADBCommand(rawValue: u32(0)) else { return nil }
        return ADBMessage(command: cmd, arg0: u32(4), arg1: u32(8), data: body)
    }
}
