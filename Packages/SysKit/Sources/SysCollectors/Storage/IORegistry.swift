// IORegistry 的小工具（存储模块用）：读属性、遍历子树、向上找父节点。都是公开 IOKit 接口。

import Foundation
import IOKit

/// 持有一个 IORegistry 对象的引用，释放时 `IOObjectRelease`。
final class IORegistryObject: @unchecked Sendable {
    let entry: io_registry_entry_t

    /// 接管一个已持有引用的对象（调用方不再释放它）。
    init?(owning entry: io_registry_entry_t) {
        guard entry != 0 else { return nil }
        self.entry = entry
    }

    deinit {
        IOObjectRelease(entry)
    }

    var registryID: UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS ? id : nil
    }

    var className: String {
        IOObjectCopyClass(entry)?.takeRetainedValue() as String? ?? ""
    }

    func conforms(to className: String) -> Bool {
        IOObjectConformsTo(entry, className) != 0
    }

    func property(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    func string(_ key: String) -> String? { property(key) as? String }
    func bool(_ key: String) -> Bool? { (property(key) as? NSNumber)?.boolValue }
    func uint64(_ key: String) -> UInt64? { (property(key) as? NSNumber)?.uint64Value }
    func dictionary(_ key: String) -> [String: Any]? { property(key) as? [String: Any] }

    /// 服务平面上的第一个父节点。
    var parent: IORegistryObject? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        return IORegistryObject(owning: parent)
    }

    /// 服务平面上的直接子节点。
    var children: [IORegistryObject] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        return Self.drain(iterator)
    }

    /// 服务平面上的全部后代（深度优先，不含自己）。
    var descendants: [IORegistryObject] {
        var iterator: io_iterator_t = 0
        guard
            IORegistryEntryCreateIterator(entry, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        return Self.drain(iterator)
    }

    /// 向上找第一个符合任一类名的祖先（含自己），最多 `limit` 层。
    func ancestor(conformingTo classNames: [String], limit: Int = 24) -> IORegistryObject? {
        var current: IORegistryObject? = self
        var depth = 0
        while let node = current, depth < limit {
            if classNames.contains(where: node.conforms(to:)) { return node }
            current = node.parent
            depth += 1
        }
        return nil
    }

    static func drain(_ iterator: io_iterator_t) -> [IORegistryObject] {
        var out: [IORegistryObject] = []
        while case let next = IOIteratorNext(iterator), next != 0 {
            if let object = IORegistryObject(owning: next) { out.append(object) }
        }
        return out
    }

    /// 匹配某个类的全部服务。
    static func services(matching className: String) -> [IORegistryObject] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        return drain(iterator)
    }

    /// 按 BSD 名找 IOMedia。
    static func media(bsdName: String) -> IORegistryObject? {
        var iterator: io_iterator_t = 0
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName),
            IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        return drain(iterator).first
    }
}
