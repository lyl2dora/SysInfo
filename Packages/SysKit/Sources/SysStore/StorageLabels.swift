// 盘与组的标签（存储模块设计 §3.1、§5）：历史库与导出里用加盐键，标签把它们对应成「型号 + 位置」。
// 标签不含序列号；RAID 名与卷名是用户起的名字，不是设备标识。导出的元数据用英文（与其余元数据一致）。

import SysModel

public enum StorageLabels {
    /// 键 → 标签。
    public static func labels(inventory: StorageInventory, groups: [CapacityGroup]) -> [String: String] {
        var out: [String: String] = [:]
        var externalIndex = 0
        for disk in inventory.disks {
            let position: String
            if let raid = disk.raid {
                let name = inventory.raidSet(raid.setKey)?.name ?? "RAID"
                position = "RAID \(name) member \(raid.index.map { "\($0 + 1)" } ?? "?")"
            } else if disk.location == .internal {
                position = "internal"
            } else {
                externalIndex += 1
                position = "external \(externalIndex)"
            }
            out[disk.key.rawValue] = "\(disk.model) · \(position)"
        }
        for set in inventory.raidSets {
            out[set.key.rawValue] = "RAID \(set.name) (\(set.level))"
        }
        for group in groups where !group.isAuxiliary {
            out[group.key.rawValue] = "volume group \(group.name) (\(group.fileSystem))"
        }
        return out
    }
}
