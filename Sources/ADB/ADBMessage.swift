import Foundation

public enum ADBCommand: UInt32, Sendable {
    case SYNC = 0x434E5953
    case CNXN = 0x4E584E43
    case AUTH = 0x48545541
    case OPEN = 0x4E45504F
    case OKAY = 0x59414B4F
    case CLSE = 0x45534C43
    case WRTE = 0x45545257
}

public struct ADBMessage: Sendable {
    public var command: ADBCommand
    public var arg0: UInt32
    public var arg1: UInt32
    public var data: Data

    public static let headerSize = 24

    public init(command: ADBCommand, arg0: UInt32, arg1: UInt32 = 0, data: Data = Data()) {
        self.command = command; self.arg0 = arg0; self.arg1 = arg1; self.data = data
    }

    var crc32: UInt32 { data.reduce(0) { $0 &+ UInt32($1) } }

    public func encode() -> Data {
        var buf = Data(capacity: Self.headerSize + data.count)
        func le(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { buf.append(contentsOf: $0) } }
        le(command.rawValue); le(arg0); le(arg1); le(UInt32(data.count)); le(crc32); le(command.rawValue ^ 0xFFFFFFFF)
        buf.append(data)
        return buf
    }

    public static func decode(header: Data, body: Data) -> ADBMessage? {
        guard header.count == headerSize else { return nil }
        func u32(_ o: Int) -> UInt32 { header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian } }
        guard let cmd = ADBCommand(rawValue: u32(0)) else { return nil }
        return ADBMessage(command: cmd, arg0: u32(4), arg1: u32(8), data: body)
    }
}
