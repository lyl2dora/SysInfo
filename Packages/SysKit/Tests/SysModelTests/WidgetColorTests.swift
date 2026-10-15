// 菜单栏 widget 颜色的持久化形式（D43）。

import Testing
import SysModel

@Suite struct WidgetColorTests {
    @Test func systemRoundTrips() {
        #expect(WidgetColor.system.storageValue == "system")
        #expect(WidgetColor(storageValue: "system") == .system)
    }

    @Test func customRoundTripsAtEightBits() {
        let color = WidgetColor.custom(red: 1, green: 0.5, blue: 0)
        #expect(color.storageValue == "#FF8000")
        #expect(WidgetColor(storageValue: "#FF8000") == .custom(red: 1, green: 128.0 / 255, blue: 0))
    }

    @Test func clampsOutOfRangeComponents() {
        #expect(WidgetColor.custom(red: -0.2, green: 1.4, blue: .nan).storageValue == "#00FF00")
    }

    @Test func rejectsMalformedValues() {
        for bad in ["", "#", "#FFF", "#GGGGGG", "FF8000", "#FF80001", "#+F8000", "red"] {
            #expect(WidgetColor(storageValue: bad) == nil)
        }
    }
}
