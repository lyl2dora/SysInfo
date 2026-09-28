// Probe: Stats ProcessReader method (Modules/CPU/readers.swift:197-199): Process("/bin/ps", ["-Aceo pid,pcpu,comm", "-r"])
import Foundation
let t = Process(); t.executableURL = URL(fileURLWithPath: "/bin/ps"); t.arguments = ["-Aceo pid,pcpu,comm", "-r"]
let p = Pipe(); t.standardOutput = p; t.standardError = Pipe()
let start = Date(); try! t.run(); let d = p.fileHandleForReading.readDataToEndOfFile(); t.waitUntilExit()
let out = String(data: d, encoding: .utf8)!
print("exit=\(t.terminationStatus) elapsed=\(String(format: "%.1f", Date().timeIntervalSince(start) * 1000))ms lines=\(out.split(separator: "\n").count)")
print(out.split(separator: "\n").prefix(12).joined(separator: "\n"))
