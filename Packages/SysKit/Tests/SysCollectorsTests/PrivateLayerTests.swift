// 私有层封装的纯函数单测（CPU 模块设计 §9）。不访问硬件。

import Testing
@testable import SysCollectors

@Suite struct PrivateLayerTests {
    /// 2：应用活动模块加入 IOPMAssertionNotify（D69）。
    @Test func layerVersionIsThreeForPowerDevices() {
        #expect(PrivateLayer.version == 3)
    }

    // MARK: SMC

    @Test func smcCommandWhitelistOnlyAllowsReads() {
        // 5 = ReadKey、8 = GetKeyFromIndex、9 = GetKeyInfo；6 = WriteKey 必须被拒绝（D18）。
        #expect(SMCReader.isCommandAllowed(5))
        #expect(SMCReader.isCommandAllowed(8))
        #expect(SMCReader.isCommandAllowed(9))
        for command in UInt8.min...UInt8.max where ![5, 8, 9].contains(command) {
            #expect(!SMCReader.isCommandAllowed(command), "命令 \(command) 不应被放行")
        }
    }

    @Test func smcKeyFourCCRoundTrip() throws {
        let key: SMCKey = "Tp01"
        #expect(key.code == 0x5470_3031)
        #expect(key.description == "Tp01")
        #expect(SMCKey(fourCC: "abc") == nil)
        #expect(SMCKey(fourCC: "Tp0é") == nil)
        #expect(SMCKey(code: 0x2341_0001).description == "#A??")
    }

    private func info(_ type: String, _ size: UInt32, littleEndian: Bool) -> SMCKeyInfo {
        SMCKeyInfo(key: "TEST", dataType: type, dataSize: size, attributes: littleEndian ? 0x84 : 0x80)
    }

    @Test func decodesFloatInBothByteOrders() {
        // 47.25 = 0x423D0000
        let be: [UInt8] = [0x42, 0x3D, 0x00, 0x00]
        #expect(SMCDecoder.decode(info("flt ", 4, littleEndian: false), bytes: be) == 47.25)
        #expect(SMCDecoder.decode(info("flt ", 4, littleEndian: true), bytes: be.reversed()) == 47.25)
    }

    @Test func decodesFixedPointAndIntegers() {
        // sp78：有符号 8.8 定点，0x1F80 = 31.5
        #expect(SMCDecoder.decode(info("sp78", 2, littleEndian: false), bytes: [0x1F, 0x80]) == 31.5)
        // ioft：16.16 定点，小端 8 字节，1.5 = 0x18000
        #expect(SMCDecoder.decode(info("ioft", 8, littleEndian: true), bytes: [0, 0x80, 1, 0, 0, 0, 0, 0]) == 1.5)
        // fpe2：无符号 14.2，0x0FA0 / 4 = 1000
        #expect(SMCDecoder.decode(info("fpe2", 2, littleEndian: false), bytes: [0x0F, 0xA0]) == 1000)
        #expect(SMCDecoder.decode(info("si16", 2, littleEndian: false), bytes: [0xFF, 0xFE]) == -2)
        #expect(SMCDecoder.decode(info("si8 ", 1, littleEndian: false), bytes: [0x80]) == -128)
        #expect(SMCDecoder.decode(info("ui32", 4, littleEndian: true), bytes: [0xD8, 0x06, 0, 0]) == 1752)
        #expect(SMCDecoder.decode(info("flag", 1, littleEndian: false), bytes: [1]) == 1)
    }

    @Test func rejectsUnknownTypesAndBadSizes() {
        #expect(SMCDecoder.decode(info("ch8*", 4, littleEndian: false), bytes: [1, 2, 3, 4]) == nil)
        #expect(SMCDecoder.decode(info("flt ", 2, littleEndian: false), bytes: [1, 2]) == nil)
        #expect(SMCDecoder.decode(info("ui32", 4, littleEndian: false), bytes: [1, 2]) == nil)
        #expect(SMCDecoder.decode(info("ui8 ", 0, littleEndian: false), bytes: []) == nil)
    }

    // MARK: coalition

    @Test func coalitionCPUTicksSumSlots24Through30() {
        var slots = [UInt64](repeating: 0, count: CoalitionUsage.bufferSlots)
        slots[3] = 999  // slot 3 不计入
        for i in 24...30 { slots[i] = UInt64(i) }
        slots[22] = 5
        slots[23] = 7
        let usage = CoalitionUsage(slots: slots)
        #expect(usage.cpuTicks == (24...30).reduce(0, +))
        #expect(usage.perfLevel0Ticks == 5)
        #expect(usage.eqosLength == CoalitionUsage.expectedEQoSLength)
    }

    @Test func coalitionCPUTicksSaturate() {
        var slots = [UInt64](repeating: 0, count: CoalitionUsage.bufferSlots)
        slots[24] = .max
        slots[25] = 1
        #expect(CoalitionUsage(slots: slots).cpuTicks == .max)
        #expect(CoalitionUsage(slots: []).cpuTicks == 0)
    }
}
