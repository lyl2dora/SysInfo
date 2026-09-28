// smcraw.swift - independent READ-ONLY AppleSMC reader using a raw 80-byte buffer with explicit offsets
// (not a C struct), selectors 9 (keyinfo) and 5 (read) only. Never writes.
// Usage: smcraw keys K1 K2 ...           -> type, size, attr, raw hex, decoded (flt LE / ioft / ints both endians)
//        smcraw watch N ms K1 K2 ...     -> timestamped values (ms since start)
import Foundation
import IOKit

let OFF_KEY = 0, OFF_KI_SIZE = 28, OFF_KI_TYPE = 32, OFF_KI_ATTR = 36, OFF_RESULT = 40, OFF_DATA8 = 42, OFF_DATA32 = 44, OFF_BYTES = 48
var conn: io_connect_t = 0
func fcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
func str(_ v: UInt32) -> String { String(bytes: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)], encoding: .ascii) ?? "?" }
func put32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) { withUnsafeBytes(of: v) { for i in 0..<4 { b[off + i] = $0[i] } } } // host (LE) order, as the kernel struct expects
func get32(_ b: [UInt8], _ off: Int) -> UInt32 { UInt32(b[off]) | UInt32(b[off+1]) << 8 | UInt32(b[off+2]) << 16 | UInt32(b[off+3]) << 24 }
func call(_ inb: [UInt8]) -> ([UInt8], kern_return_t) {
    var out = [UInt8](repeating: 0, count: 80); var osz = 80
    let kr = inb.withUnsafeBytes { ip in out.withUnsafeMutableBytes { op in IOConnectCallStructMethod(conn, 2, ip.baseAddress, 80, op.baseAddress, &osz) } }
    return (out, kr)
}
struct Val { let type: String; let size: UInt32; let attr: UInt8; let bytes: [UInt8] }
func read(_ key: String) -> (Val?, String) {
    var i = [UInt8](repeating: 0, count: 80); put32(&i, OFF_KEY, fcc(key)); i[OFF_DATA8] = 9
    let (o, kr) = call(i); if kr != KERN_SUCCESS { return (nil, String(format: "kr=0x%x", kr)) }
    if o[OFF_RESULT] != 0 { return (nil, String(format: "info smc result=0x%02x", o[OFF_RESULT])) }
    let size = get32(o, OFF_KI_SIZE), type = get32(o, OFF_KI_TYPE), attr = o[OFF_KI_ATTR]
    var r = [UInt8](repeating: 0, count: 80); put32(&r, OFF_KEY, fcc(key)); put32(&r, OFF_KI_SIZE, size); r[OFF_DATA8] = 5
    let (o2, kr2) = call(r); if kr2 != KERN_SUCCESS { return (nil, String(format: "read kr=0x%x", kr2)) }
    if o2[OFF_RESULT] != 0 { return (nil, String(format: "read smc result=0x%02x", o2[OFF_RESULT])) }
    return (Val(type: str(type), size: size, attr: attr, bytes: Array(o2[OFF_BYTES..<OFF_BYTES + Int(min(size, 32))])), "")
}
func decode(_ v: Val) -> String {
    let b = v.bytes
    switch v.type {
    case "flt ": return String(format: "%.4f", b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
    case "ioft": return String(format: "%.4f", Double(b.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / 65536.0)
    case "ui8 ", "flag": return "\(b[0])"
    case "ui16": return "BE=\(UInt16(b[0]) << 8 | UInt16(b[1])) LE=\(UInt16(b[1]) << 8 | UInt16(b[0]))"
    case "ui32", "si32": let le = get32(b, 0); let be = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        return v.type == "si32" ? "BE=\(Int32(bitPattern: be)) LE=\(Int32(bitPattern: le))" : "BE=\(be) LE=\(le)"
    default: return b.map { String(format: "%02x", $0) }.joined()
    }
}
let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
guard svc != 0, IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { print("open failed"); exit(1) }
let a = CommandLine.arguments
if a.count > 2 && a[1] == "keys" {
    for k in a[2...] { let (v, e) = read(k); if let v { print("\(k) \(v.type) \(v.size) attr=0x\(String(v.attr, radix: 16)) raw=\(v.bytes.map { String(format: "%02x", $0) }.joined()) -> \(decode(v))") } else { print("\(k) ERR \(e)") } }
} else if a.count > 4 && a[1] == "watch" {
    let n = Int(a[2])!, ms = Int(a[3])!; let keys = Array(a[4...]); let t0 = Date()
    print("t_ms " + keys.joined(separator: " "))
    for s in 0..<n {
        var line = String(format: "%6.0f", Date().timeIntervalSince(t0) * 1000)
        for k in keys { let (v, _) = read(k); line += " " + (v.map { decode($0) } ?? "ERR") }
        print(line); fflush(stdout)
        if s < n - 1 { usleep(useconds_t(ms * 1000)) }
    }
}
IOServiceClose(conn)
