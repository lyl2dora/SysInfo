// 拖拽排序的纯逻辑（D92）。

import Testing
import SysModel

@Suite struct ReorderListTests {
    let items = ["a", "b", "c", "d"]

    @Test func movesForwardAndBackward() {
        #expect(ReorderList.applying(sources: ["a"], before: "c", to: items) == ["b", "a", "c", "d"])
        #expect(ReorderList.applying(sources: ["d"], before: "a", to: items) == ["d", "a", "b", "c"])
        #expect(ReorderList.applying(sources: ["b"], before: nil, to: items) == ["a", "c", "d", "b"])
    }

    @Test func movesSeveralInSelectionOrder() {
        #expect(ReorderList.applying(sources: ["d", "a"], before: "c", to: items) == ["b", "d", "a", "c"])
    }

    @Test func dropBeforeItselfKeepsPlace() {
        #expect(ReorderList.applying(sources: ["b"], before: "b", to: items) == items)
        // 目标也在被拖的项里：插到它之后第一个没被拖的项之前
        #expect(ReorderList.applying(sources: ["c", "b"], before: "b", to: items) == ["a", "c", "b", "d"])
        #expect(ReorderList.applying(sources: ["c", "d"], before: "d", to: items) == ["a", "b", "c", "d"])
    }

    @Test func ignoresUnknownIDs() {
        #expect(ReorderList.applying(sources: ["x"], before: "a", to: items) == items)
        #expect(ReorderList.applying(sources: ["a"], before: "x", to: items) == ["b", "c", "d", "a"])
    }
}
