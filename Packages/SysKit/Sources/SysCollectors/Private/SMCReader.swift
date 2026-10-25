// AppleSMC 只读访问的 Swift 封装（CPU 模块设计 §3、§5.5；CLAUDE.md「已知陷阱」的 SMC 条）。
//
// - 只读：私有 C 层只放了三个读命令，写命令在代码里不存在（D18）；
// - 字节序按属性位判断（位 0x04 置位为小端），支持 flt、ioft、sp78、fpe2、si*/ui*、flag 等类型，并检查 result 字节；
// - key-info 在内存里缓存：读一个键只需一次 IOConnectCall。按系统 build 持久化缓存由 SensorCollector 负责（§5.5）；
// - 读取是阻塞的（M5 每键墙钟约 0.2 ms），只能在采样线程或阻塞通道上调用，不能放在 MainActor（D03）。

import Synchronization
internal import CSysPrivate

/// SMC 键的四字符码，例如 `Tp01`、`RP00`。
public struct SMCKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let code: UInt32

    public init(code: UInt32) {
        self.code = code
    }

    /// 由四个 ASCII 字符构造；长度不是 4 或含非 ASCII 字符时返回 nil。
    public init?(fourCC string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        code = bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    public init(stringLiteral value: String) {
        guard let key = SMCKey(fourCC: value) else { preconditionFailure("SMC 键必须是 4 个 ASCII 字符：\(value)") }
        self = key
    }

    public var description: String { Self.fourCC(code) }

    public static func < (lhs: SMCKey, rhs: SMCKey) -> Bool { lhs.code < rhs.code }

    /// 四字符码转字符串；不可打印的字节用 `?` 代替。
    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        return String(decoding: bytes.map { (0x20..<0x7F).contains($0) ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let string = try c.decode(String.self)
        guard let key = SMCKey(fourCC: string) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "不是合法的 SMC 键：\(string)")
        }
        self = key
    }
}

/// 一个键的元信息（来自 kSMCGetKeyInfo）。
public struct SMCKeyInfo: Hashable, Codable, Sendable {
    public var key: SMCKey
    /// 类型码，例如 `flt `、`ui32`（含尾随空格）。
    public var dataType: String
    public var dataSize: UInt32
    public var attributes: UInt8

    public init(key: SMCKey, dataType: String, dataSize: UInt32, attributes: UInt8) {
        self.key = key
        self.dataType = dataType
        self.dataSize = dataSize
        self.attributes = attributes
    }

    /// 属性位 0x04 置位表示小端（调研报告 §1.6）。
    public var isLittleEndian: Bool { attributes & 0x04 != 0 }
}

/// 读 SMC 失败的原因。
public enum SMCError: Error, Hashable, Sendable, CustomStringConvertible {
    /// 打不开 AppleSMC 用户客户端（附 kern_return_t）。
    case openFailed(Int32)
    /// IOKit 调用失败（附 kern_return_t）。
    case callFailed(Int32)
    /// SMC 返回了非 0 的结果字节，例如键不存在。
    case smcResult(UInt8)
    /// 数据长度超出 32 字节，或与类型不符。
    case badSize(UInt32)

    public var description: String {
        switch self {
        case .openFailed(let kr): "openFailed(kr=\(kr))"
        case .callFailed(let kr): "callFailed(kr=\(kr))"
        case .smcResult(let r): "smcResult(\(r))"
        case .badSize(let s): "badSize(\(s))"
        }
    }
}

/// 解码 SMC 原始字节（纯函数，单测覆盖）。
public enum SMCDecoder {
    /// 按类型码和字节序把原始字节解码成数值；不认识的类型或长度不符时返回 nil。
    public static func decode(_ info: SMCKeyInfo, bytes: [UInt8]) -> Double? {
        let n = Int(info.dataSize)
        guard n > 0, n <= bytes.count else { return nil }
        let raw = Array(bytes.prefix(n))
        func unsigned() -> UInt64 {
            let ordered = info.isLittleEndian ? raw.reversed() : raw
            return ordered.reduce(0) { $0 << 8 | UInt64($1) }
        }
        switch (info.dataType, n) {
        case ("flt ", 4): return Double(Float(bitPattern: UInt32(truncatingIfNeeded: unsigned())))
        case ("ioft", 8): return Double(Int64(bitPattern: unsigned())) / 65536
        case ("ioft", 4): return Double(Int32(truncatingIfNeeded: unsigned())) / 65536
        case ("sp78", 2): return Double(Int16(truncatingIfNeeded: unsigned())) / 256
        case ("fpe2", 2): return Double(UInt16(truncatingIfNeeded: unsigned())) / 4
        case ("si8 ", 1): return Double(Int8(bitPattern: raw[0]))
        case ("si16", 2): return Double(Int16(truncatingIfNeeded: unsigned()))
        case ("si32", 4): return Double(Int32(truncatingIfNeeded: unsigned()))
        case ("si64", 8): return Double(Int64(bitPattern: unsigned()))
        case ("ui8 ", 1), ("flag", 1): return Double(raw[0])
        case ("ui16", 2), ("ui32", 4), ("ui64", 8): return Double(unsigned())
        default: return nil
        }
    }
}

/// AppleSMC 的只读连接。
///
/// 连接和 key-info 缓存放在 `Mutex` 里：同一时刻只有一个线程在读（SMC 的用户客户端本身也是串行的）。
public final class SMCReader: Sendable {
    private struct State: ~Copyable {
        var connection: UInt32 = 0
        var keyInfo: [SMCKey: SMCKeyInfo] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    deinit {
        state.withLock { s in
            csp_smc_close(s.connection)
            s.connection = 0
        }
    }

    /// 打开连接（已打开时直接返回）。
    public func open() throws(SMCError) {
        try state.withLock { s throws(SMCError) in
            try Self.ensureOpen(&s)
        }
    }

    /// SMC 自报的键总数（`#KEY`）。
    public func keyCount() throws(SMCError) -> Int {
        let info = try keyInfo(for: "#KEY")
        guard let value = SMCDecoder.decode(info, bytes: try readRaw(info)), value >= 0 else {
            throw .badSize(info.dataSize)
        }
        return Int(value)
    }

    /// 全量枚举键名（M5 约 2455 个，M4 1728 个；约 15–25 ms）。单个索引失败时跳过。
    public func allKeys() throws(SMCError) -> [SMCKey] {
        let count = try keyCount()
        return try state.withLock { s throws(SMCError) in
            try Self.ensureOpen(&s)
            var keys: [SMCKey] = []
            keys.reserveCapacity(count)
            for index in 0..<UInt32(count) {
                var code: UInt32 = 0
                var result: UInt8 = 0
                let kr = csp_smc_key_at_index(s.connection, index, &code, &result)
                if kr == 0, result == 0 { keys.append(SMCKey(code: code)) }
            }
            return keys
        }
    }

    /// 键的元信息；命中缓存时不访问 SMC。
    public func keyInfo(for key: SMCKey) throws(SMCError) -> SMCKeyInfo {
        try state.withLock { s throws(SMCError) in
            if let hit = s.keyInfo[key] { return hit }
            try Self.ensureOpen(&s)
            var raw = csp_smc_key_info()
            let kr = csp_smc_get_key_info(s.connection, key.code, &raw)
            guard kr == 0 else {
                Self.dropConnection(&s)  // IPC 层失败（服务重启、连接失效）：下次调用重新打开
                throw .callFailed(kr)
            }
            guard raw.result == 0 else { throw .smcResult(raw.result) }
            let info = SMCKeyInfo(
                key: key, dataType: SMCKey.fourCC(raw.data_type), dataSize: raw.data_size,
                attributes: raw.data_attributes)
            s.keyInfo[key] = info
            return info
        }
    }

    /// 预先放入 key-info（例如从按系统 build 持久化的缓存里恢复）。
    public func seedKeyInfo(_ infos: [SMCKeyInfo]) {
        state.withLock { s in
            for info in infos { s.keyInfo[info.key] = info }
        }
    }

    /// 读一个键的原始字节。
    public func readRaw(_ info: SMCKeyInfo) throws(SMCError) -> [UInt8] {
        guard info.dataSize > 0, info.dataSize <= 32 else { throw .badSize(info.dataSize) }
        return try state.withLock { s throws(SMCError) in
            try Self.ensureOpen(&s)
            var bytes = [UInt8](repeating: 0, count: 32)
            var result: UInt8 = 0
            let kr = bytes.withUnsafeMutableBufferPointer { buffer in
                csp_smc_read_key(s.connection, info.key.code, info.dataSize, buffer.baseAddress!, &result)
            }
            guard kr == 0 else {
                Self.dropConnection(&s)  // IPC 层失败（服务重启、连接失效）：下次调用重新打开
                throw .callFailed(kr)
            }
            guard result == 0 else { throw .smcResult(result) }
            return Array(bytes.prefix(Int(info.dataSize)))
        }
    }

    /// 读一个键并解码成数值；不能按数值解码时返回 nil。
    public func readValue(_ key: SMCKey) throws(SMCError) -> Double? {
        let info = try keyInfo(for: key)
        return SMCDecoder.decode(info, bytes: try readRaw(info))
    }

    /// 批量读取：每个键单独成败，失败的为 nil。
    public func readValues(_ keys: [SMCKey]) -> [SMCKey: Double] {
        var out: [SMCKey: Double] = [:]
        out.reserveCapacity(keys.count)
        for key in keys {
            if let value = try? readValue(key) { out[key] = value }
        }
        return out
    }

    /// 私有层的命令白名单是否放行 `command`（单测核对写命令被拒绝）。
    static func isCommandAllowed(_ command: UInt8) -> Bool {
        csp_smc_command_allowed(command) != 0
    }

    private static func dropConnection(_ s: inout State) {
        guard s.connection != 0 else { return }
        csp_smc_close(s.connection)
        s.connection = 0
    }

    private static func ensureOpen(_ s: inout State) throws(SMCError) {
        guard s.connection == 0 else { return }
        var connection: UInt32 = 0
        let kr = csp_smc_open(&connection)
        guard kr == 0, connection != 0 else { throw .openFailed(kr) }
        s.connection = connection
    }
}
