// DiskArbitration + NSWorkspace mount/unmount event probe.
// Creates its OWN 20 MB disk image in this probe dir, attaches it (once -nobrowse, once browsable), then detaches it.
import Foundation
import DiskArbitration
import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
let img = dir + "/probe_evt.dmg"
let t0 = Date()
func ts() -> String { String(format: "%6.2fs", Date().timeIntervalSince(t0)) }
var initialDone = false
var initialCount = 0

func desc(_ disk: DADisk) -> String {
    let bsd = DADiskGetBSDName(disk).map { String(cString: $0) } ?? "?"
    let d = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
    let path = (d[kDADiskDescriptionVolumePathKey as String] as? URL)?.path ?? "-"
    let name = d[kDADiskDescriptionVolumeNameKey as String] as? String ?? "-"
    let kind = d[kDADiskDescriptionVolumeKindKey as String] as? String ?? "-"
    let proto = d[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? "-"
    return "bsd=\(bsd) name=\(name) kind=\(kind) path=\(path) protocol=\(proto)"
}

let session = DASessionCreate(kCFAllocatorDefault)!
DASessionSetDispatchQueue(session, DispatchQueue.main)
DARegisterDiskAppearedCallback(session, nil, { disk, _ in
    if !initialDone { initialCount += 1; return }
    print("\(ts()) DA appeared    \(desc(disk))")
}, nil)
DARegisterDiskDisappearedCallback(session, nil, { disk, _ in print("\(ts()) DA disappeared \(desc(disk))") }, nil)
DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, keys, _ in
    print("\(ts()) DA descChanged keys=\((keys as? [String]) ?? []) \(desc(disk))")
}, nil)

let nc = NSWorkspace.shared.notificationCenter
for n in [NSWorkspace.didMountNotification, NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
    nc.addObserver(forName: n, object: nil, queue: .main) { note in
        let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
        print("\(ts()) NSWorkspace \(n.rawValue) url=\(url?.path ?? "-") name=\(note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] ?? "-")")
    }
}

@discardableResult func run(_ tool: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    let pipe = Pipe(); let epipe = Pipe(); p.standardOutput = pipe; p.standardError = epipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: epipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    print("\(ts()) $ \((tool as NSString).lastPathComponent) \(args.joined(separator: " ")) -> exit \(p.terminationStatus)\(err.isEmpty ? "" : " stderr=" + err.trimmingCharacters(in: .whitespacesAndNewlines))")
    return out
}
// first /dev/diskN line of attach output = whole image device
func devOf(_ out: String) -> String? {
    out.split(separator: "\n").compactMap { l -> String? in let f = l.split(separator: "\t").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""; return f.hasPrefix("/dev/disk") ? f : nil }.first
}

DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    initialDone = true
    print("\(ts()) initial DA appeared callbacks for existing disks: \(initialCount)")
    DispatchQueue.global().async {
        try? FileManager.default.removeItem(atPath: img)
        run("/usr/sbin/diskutil", ["image", "create", "blank", "--size", "20m", "--fs", "APFS", "--volumeName", "ProbeEvt", img])
        Thread.sleep(forTimeInterval: 1)
        for browse in [false, true] {
            var args = ["image", "attach", img]; if !browse { args.append("--nobrowse") }
            let out = run("/usr/sbin/diskutil", args)
            let dev = devOf(out)
            print("\(ts()) attached dev=\(dev ?? "?") browsable=\(browse) out=\(out.replacingOccurrences(of: "\n", with: " | "))")
            Thread.sleep(forTimeInterval: 3)
            if let dev { run("/usr/sbin/diskutil", ["eject", dev]) }
            Thread.sleep(forTimeInterval: 3)
        }
        try? FileManager.default.removeItem(atPath: img)
        DispatchQueue.main.async { print("\(ts()) done"); exit(0) }
    }
}
RunLoop.main.run()
