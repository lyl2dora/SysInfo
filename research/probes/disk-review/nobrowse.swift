// Review probe: does `diskutil image attach --nobrowse` really set MNT_DONTBROWSE, and does NSWorkspace still post didMount?
// Uses its OWN 10 MB image in this directory; ejects it afterwards.
import Foundation
import AppKit
let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
let img = dir + "/rv_nobrowse.dmg"
let t0 = Date(); func ts() -> String { String(format: "%5.2fs", Date().timeIntervalSince(t0)) }
for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
    NSWorkspace.shared.notificationCenter.addObserver(forName: n, object: nil, queue: .main) { note in
        print("\(ts()) NSWorkspace \(n.rawValue) \((note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path ?? "-")")
    }
}
func run(_ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil"); p.arguments = args
    let o = Pipe(); p.standardOutput = o; p.standardError = o; try? p.run(); p.waitUntilExit()
    let s = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    print("\(ts()) $ diskutil \(args.joined(separator: " ")) -> \(p.terminationStatus)"); return s
}
DispatchQueue.global().async {
    try? FileManager.default.removeItem(atPath: img)
    _ = run(["image", "create", "blank", "--size", "10m", "--fs", "APFS", "--volumeName", "RvNoBrowse", img])
    Thread.sleep(forTimeInterval: 1.5)
    for args in [["--nobrowse"], ["--mountOptions", "nobrowse"], []] {
        let out = run(["image", "attach", img] + args)
        let dev = out.split(separator: "\n").compactMap { $0.split(separator: "\t").first.map { $0.trimmingCharacters(in: .whitespaces) } }.first { $0.hasPrefix("/dev/disk") }
        let mp = out.split(separator: "\n").compactMap { l -> String? in let f = l.split(separator: "\t"); return f.count >= 3 ? f.last!.trimmingCharacters(in: .whitespaces) : nil }.first { $0.hasPrefix("/") }
        var s = statfs(); let rc = mp.map { statfs($0, &s) } ?? -1
        let dontBrowse = rc == 0 && (s.f_flags & UInt32(MNT_DONTBROWSE)) != 0
        let visible = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])?.map { $0.path } ?? []
        print("\(ts())   args=\(args) dev=\(dev ?? "?") mp=\(mp ?? "?") MNT_DONTBROWSE=\(dontBrowse) inSkipHiddenList=\(mp.map { visible.contains($0) } ?? false)")
        Thread.sleep(forTimeInterval: 2)
        if let dev { _ = run(["eject", dev]) }
        Thread.sleep(forTimeInterval: 2)
    }
    try? FileManager.default.removeItem(atPath: img)
    DispatchQueue.main.async { print("\(ts()) done"); exit(0) }
}
RunLoop.main.run()
