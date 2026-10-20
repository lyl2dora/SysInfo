// 拖拽排序的纯逻辑（D92）：SwiftUI 27 的 `reorderContainer` 只给出「拖了哪些项、放到哪一项之前（或末尾）」，
// SDK 里没有现成的 apply 函数，这里按这个语义算出新顺序。

public enum ReorderList {
    /// 把 `sources` 按给定的先后取出，插到 `before` 之前；`before` 为 nil 时放到末尾。
    /// - 不在 `items` 里的 source 忽略；
    /// - `before` 本身也在被拖的项里时，插到它之后第一个没被拖的项之前（没有就放到末尾）；
    /// - `before` 不在 `items` 里时放到末尾。
    public static func applying<ID: Equatable>(sources: [ID], before: ID?, to items: [ID]) -> [ID] {
        let moving = sources.filter(items.contains)
        guard !moving.isEmpty else { return items }
        var anchor = before
        if let start = before, moving.contains(start), let index = items.firstIndex(of: start) {
            anchor = items[index...].first { !moving.contains($0) }
        }
        var rest = items.filter { !moving.contains($0) }
        let insertAt = anchor.flatMap { rest.firstIndex(of: $0) } ?? rest.endIndex
        rest.insert(contentsOf: moving, at: insertAt)
        return rest
    }
}
