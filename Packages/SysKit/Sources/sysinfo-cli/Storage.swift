// sysinfo-cli storage / smart / disktop / verify storage（存储模块设计 §7）。
//
// - storage：物理盘清单、每盘读写与 IOPS、SMART 摘要、容量组；
// - smart：每盘 SMART 全字段；
// - disktop：按磁盘 IO 的 Top N（coalition 6/7 号槽）；
// - verify storage：与 `iostat -d`（同一时间窗）与 `df -k` 各运行一次对照（只在手动运行时 spawn，CLAUDE.md）。
//
// 盘的键用进程内随机盐（CLI 不写偏好，远端只写 /tmp/sysinfo-remote），每次运行都不同；输出里没有序列号。

import Foundation
import SysCollectors
import SysModel

extension SysInfoCLI {
    static func decimalBytes(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = bytes
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return unit == 0 ? String(format: "%.0f B", value) : String(format: value < 10 ? "%.2f %@" : "%.1f %@", value, units[unit])
    }

    static func diskTitle(_ disk: PhysicalDisk, inventory: StorageInventory) -> String {
        var parts = ["\(disk.bsdName ?? "?")", disk.model, disk.location == .internal ? "内置" : "外置", disk.interconnect]
        if let raid = disk.raid {
            let name = inventory.raidSet(raid.setKey)?.name ?? "RAID"
            parts.append("RAID「\(name)」成员 \(raid.index.map { "\($0 + 1)" } ?? "?") · \(raid.status)")
        }
        return parts.joined(separator: " · ")
    }

    static func runStorage(interval: Double, count: Int, json: Bool) -> Int32 {
        let io = StorageIOCollector()
        let smart = SMARTCollector()
        let capacity = StorageCapacityCollector()
        let collectors: [any Collector] = [io, smart, capacity]
        for collector in collectors {
            let result = collector.selfTest()
            for check in result.checks where !check.passed || !json {
                let mark = check.passed ? "✓" : check.severity == .advisory ? "!" : "✗"
                printError("    \(mark) \(check.name)：\(check.detail)")
            }
        }
        let inventory = DiskInventory.shared.inventory
        let encoder = makeEncoder()
        if json {
            struct Header: Encodable { var machine: MachineInfo; var inventory: StorageInventory; var groups: [CapacityGroup] }
            if let data = try? encoder.encode(Header(machine: .current, inventory: inventory, groups: capacity.latestGroups)) {
                print(String(decoding: data, as: UTF8.self))
            }
        } else {
            print(machineLine())
            print("物理盘 \(inventory.disks.count) 块，RAID 组 \(inventory.raidSets.count) 个")
            for set in inventory.raidSets {
                print("  RAID「\(set.name)」\(set.level) · \(set.status) · \(set.sizeBytes.map { decimalBytes(Double($0)) } ?? "—") · 成员 \(set.members.count)")
            }
            for group in capacity.latestGroups {
                let owner: String =
                    switch group.owner {
                    case .disk(let key): inventory.disk(key)?.bsdName ?? "?"
                    case .raid(let key): "RAID「\(inventory.raidSet(key)?.name ?? "?")」"
                    }
                print(
                    "  容量组「\(group.name)」\(group.fileSystem) · \(owner)\(group.isBoot ? " · 启动" : "")\(group.isAuxiliary ? " · 辅助" : "")"
                        + " · 已用 \(decimalBytes(Double(group.usedBytes))) / \(decimalBytes(Double(group.totalBytes)))"
                        + " · 可用 \(decimalBytes(Double(group.availableBytes)))"
                        + (group.purgeableBytes.map { " · 可清除 \(decimalBytes(Double($0)))" } ?? ""))
                for volume in group.volumes {
                    print(
                        "      \(volume.bsdName ?? "?") \(volume.name) [\(volume.role ?? "—")] \(volume.mountPoint ?? "未挂载")"
                            + (volume.usedBytes.map { " · \(decimalBytes(Double($0)))" } ?? ""))
                }
            }
        }
        var deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for index in 0...count {
            if index > 0 {
                deadline += UInt64(interval * 1e9)
                sleep(untilUptimeNanos: deadline)
            }
            let now = SampleTime.now()
            var costs: [String] = []
            var samples: [Sample] = []
            for collector in collectors {
                let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                samples += collector.sample(at: now).samples
                costs.append(String(format: "%@ %.2f ms", collector.id.rawValue, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6))
            }
            guard index > 0 else { continue }  // 第 0 次只建立读写基线
            if json {
                struct Record: Encodable { var index: Int; var samples: [Sample] }
                if let data = try? encoder.encode(Record(index: index, samples: samples)) { print(String(decoding: data, as: UTF8.self)) }
                continue
            }
            let byID: [MetricID: Sample] = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            print("#\(index)  CPU：\(costs.joined(separator: "，"))")
            for disk in inventory.disks {
                func value(_ metric: MetricID.DiskMetric) -> Double? { byID[.storageDisk(disk.key, metric)]?.value }
                func rate(_ metric: MetricID.DiskMetric) -> String { value(metric).map { decimalBytes($0) + "/s" } ?? "—" }
                func ms(_ metric: MetricID.DiskMetric) -> String { value(metric).map { String(format: "%.2f ms", $0 * 1000) } ?? "—" }
                let temp = value(.temp).map { String(format: "%.0f °C", $0) } ?? "—"
                let life = value(.life).map { String(format: "%.0f%%", $0 * 100) } ?? "—"
                print("  \(diskTitle(disk, inventory: inventory))")
                print(
                    "      读 \(rate(.read)) \(value(.readOps).map { String(format: "%.0f", $0) } ?? "—") IOPS \(ms(.readLatency))"
                        + " · 写 \(rate(.write)) \(value(.writeOps).map { String(format: "%.0f", $0) } ?? "—") IOPS \(ms(.writeLatency))"
                        + " · \(temp) · 寿命已用 \(life)")
            }
        }
        return 0
    }

    static func runSMART(json: Bool) -> Int32 {
        let smart = SMARTCollector()
        _ = smart.selfTest()
        let inventory = DiskInventory.shared.inventory
        let records = smart.latestRecords
        if json {
            struct Entry: Encodable { var disk: PhysicalDisk; var smart: SMARTRecord? }
            struct Report: Encodable { var machine: MachineInfo; var disks: [Entry] }
            let report = Report(machine: .current, disks: inventory.disks.map { Entry(disk: $0, smart: records[$0.key]) })
            if let data = try? makeEncoder().encode(report) { print(String(decoding: data, as: UTF8.self)) }
            return 0
        }
        print(machineLine())
        for disk in inventory.disks {
            print(diskTitle(disk, inventory: inventory))
            guard let r = records[disk.key] else {
                print("    SMART：\(smart.statuses[disk.key].map { "\($0.state)" } ?? "不可用")")
                continue
            }
            print(
                "    critical warning 0x\(String(r.criticalWarning.rawValue, radix: 16)) · 综合温度 \(Int(r.temperatureCelsius)) °C"
                    + " · 备用块 \(r.availableSpare)%（阈值 \(r.availableSpareThreshold)%）· 已用寿命 \(r.percentageUsed)%")
            print(
                "    读 \(decimalBytes(r.bytesRead)) · 写 \(decimalBytes(r.bytesWritten)) · 主机读命令 \(Int(r.hostReadCommands))"
                    + " · 主机写命令 \(Int(r.hostWriteCommands))")
            print(
                "    忙碌 \(r.controllerBusyUnsupported ? "不支持" : "\(Int(r.controllerBusyMinutes)) 分") · 通电 \(Int(r.powerCycles)) 次"
                    + " · 通电时间 \(Int(r.powerOnHours)) h\(r.powerOnHoursUnreliable ? "（控制器低报）" : "")"
                    + " · 异常断电 \(Int(r.unsafeShutdowns)) · 介质错误 \(Int(r.mediaErrors)) · 错误日志 \(Int(r.errorLogEntries))")
            let sensors = r.temperatureSensors.enumerated().compactMap { i, t in t.map { "T\(i + 1) \(Int($0)) °C" } }
            print(
                "    超警告温度 \(r.warningTemperatureMinutes) 分 · 超严重温度 \(r.criticalTemperatureMinutes) 分"
                    + " · 阈值 \(r.warningThresholdCelsius.map { "\(Int($0))" } ?? "—") / \(r.criticalThresholdCelsius.map { "\(Int($0))" } ?? "—") °C"
                    + " · 传感器 \(sensors.isEmpty ? "无" : sensors.joined(separator: " "))"
                    + " · 热管理 \(r.thermalTransitions.map(String.init).joined(separator: "/")) 次 \(r.thermalSeconds.map(String.init).joined(separator: "/")) s")
            print(
                "    VID 0x\(String(r.vendorID ?? 0, radix: 16)) · NVMe 版本 0x\(String(r.nvmeVersion ?? 0, radix: 16))"
                    + " · 读取 \(smart.statuses[disk.key]?.lastCPUNanos.map { String(format: "%.3f ms CPU", Double($0) / 1e6) } ?? "—")")
        }
        return 0
    }

    /// 与 iostat（同一时间窗）和 df 对照。
    static func runVerifyStorage(seconds: Int) -> Int32 {
        let io = StorageIOCollector()
        let capacity = StorageCapacityCollector()
        _ = io.selfTest()
        _ = capacity.selfTest()
        let inventory = DiskInventory.shared.inventory
        let names = inventory.disks.compactMap(\.bsdName)
        print("\(machineLine()) · 与 iostat -d（\(seconds) s 窗口）和 df -k 对照")
        _ = io.sample(at: .now())
        // iostat 的第二行是这段时间的平均值（第一行是开机以来）；同时开始，同时结束。
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let iostat = capture("/usr/sbin/iostat", ["-d", "-K", "-c", "2", "-w", "\(seconds)"] + names)
        let elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9
        let samples = io.sample(at: .now()).samples
        let byID: [MetricID: Sample] = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        var passed = true
        if let iostat, let last = iostat.split(separator: "\n").last {
            // 每块盘三列：KB/t、tps、MB/s（MB = 1048576）。
            let fields = last.split(separator: " ", omittingEmptySubsequences: true).compactMap { Double($0) }
            for (i, disk) in inventory.disks.enumerated() where fields.count >= (i + 1) * 3 {
                let theirs = fields[i * 3 + 2] * 1_048_576
                let ours = (byID[.storageDisk(disk.key, .read)]?.value ?? 0) + (byID[.storageDisk(disk.key, .write)]?.value ?? 0)
                let tps = fields[i * 3 + 1]
                let oursOps = (byID[.storageDisk(disk.key, .readOps)]?.value ?? 0) + (byID[.storageDisk(disk.key, .writeOps)]?.value ?? 0)
                // iostat 只给两位小数的 MB/s：允许 5% 或 0.02 MB/s（取大）。
                let ok = abs(ours - theirs) <= max(theirs * 0.05, 0.02 * 1_048_576)
                passed = passed && ok
                print(
                    String(
                        format: "  %@ %@：SysInfo %.3f MB/s %.1f IOPS · iostat %.3f MB/s %.1f tps", ok ? "✓" : "✗", disk.bsdName ?? "?",
                        ours / 1_048_576, oursOps, theirs / 1_048_576, tps))
            }
        } else {
            print("  iostat 运行失败")
            passed = false
        }
        print(String(format: "  （窗口 %.1f s）", elapsed))
        if let df = capture("/bin/df", ["-k"]) {
            for group in capacity.latestGroups where !group.isAuxiliary {
                guard let mount = group.volumes.compactMap(\.mountPoint).first,
                    let line = df.split(separator: "\n").first(where: { $0.hasSuffix(" " + mount) })
                else { continue }
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 4, let size = Double(fields[1]), let available = Double(fields[3]) else { continue }
                let ok = abs(Double(group.availableBytes) - available * 1024) <= max(available * 1024 * 0.001, 64 * 1_048_576)
                passed = passed && ok
                print(
                    "  \(ok ? "✓" : "✗") 容量组「\(group.name)」可用 \(decimalBytes(Double(group.availableBytes))) · df \(decimalBytes(available * 1024))"
                        + "（df 的 Size \(decimalBytes(size * 1024)) 是该卷的统计，APFS 容器总量另见 diskutil）")
            }
        }
        print(passed ? "全部一致" : "有不一致的项")
        return passed ? 0 : 1
    }
}
