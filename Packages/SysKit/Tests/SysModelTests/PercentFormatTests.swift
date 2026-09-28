// 百分比格式化（K24，M0 设计 §8）。用二进制可精确表示的比例（x.5% 这类）来测舍入方向。

import Testing
import SysModel

@Suite struct PercentFormatTests {
    @Test(arguments: [
        (0.0, "0%"),
        (1.0, "100%"),
        (0.5, "50%"),
        (0.125, "13%"),  // 12.5 → 13：四舍五入，不是银行家舍入（后者得 12）
        (0.375, "38%"),  // 37.5 → 38
        (0.625, "63%"),  // 62.5 → 63
        (0.0625, "6%"),  // 6.25 → 6
        (1.5, "150%"),  // 本进程 CPU 按单核计，可以超过 100%
    ])
    func wholePercent(ratio: Double, expected: String) {
        #expect(PercentFormat.string(fromRatio: ratio) == expected)
    }

    @Test func fractionDigits() {
        #expect(PercentFormat.string(fromRatio: 0.125, fractionDigits: 1) == "12.5%")
        #expect(PercentFormat.string(fromRatio: 0.0625, fractionDigits: 1) == "6.3%")  // 6.25 → 6.3
        #expect(PercentFormat.string(fromRatio: 0.5, fractionDigits: 2) == "50.00%")
        // 位数钳在 0…6
        #expect(PercentFormat.string(fromRatio: 0.5, fractionDigits: -3) == "50%")
    }

    @Test func negativeValuesClampToZero() {
        #expect(PercentFormat.string(fromRatio: -0.0) == "0%")
        #expect(PercentFormat.string(fromRatio: -0.2) == "0%")
        #expect(PercentFormat.string(fromRatio: -0.001, fractionDigits: 1) == "0.0%")
    }

    @Test func nonFiniteValuesUsePlaceholder() {
        #expect(PercentFormat.string(fromRatio: .nan) == PercentFormat.placeholder)
        #expect(PercentFormat.string(fromRatio: .infinity) == PercentFormat.placeholder)
        #expect(PercentFormat.string(fromRatio: -.infinity) == PercentFormat.placeholder)
    }
}
