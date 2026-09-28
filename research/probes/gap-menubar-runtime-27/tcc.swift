import AppKit
import ApplicationServices
import CoreGraphics
print("CGPreflightScreenCaptureAccess =", CGPreflightScreenCaptureAccess())
print("AXIsProcessTrusted =", AXIsProcessTrusted())
// parent chain
var pid = getpid()
for _ in 0..<8 {
  var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  sysctl(&mib, 4, &info, &size, nil, 0)
  let name = withUnsafePointer(to: info.kp_proc.p_comm) { $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) } }
  print("pid \(pid) \(name) ppid \(info.kp_eproc.e_ppid)")
  pid = info.kp_eproc.e_ppid; if pid <= 1 { break }
}
