// 一个消费者的采样需求槽（M0 设计 §5.2、§6）：菜单栏 item、面板、诊断页各持有一个。
//
// set(nil) 注销；set(新需求) 先注销旧的再登记新的。登记是异步的（引擎是 actor），
// 用代数计数丢弃过时的登记结果，保证最终状态与最后一次 set 一致。

import SysCollectors

final class DemandSlot {
    private let engine: SamplingEngine
    private(set) var demand: Demand?
    private var token: DemandToken?
    private var generation = 0

    init(engine: SamplingEngine) {
        self.engine = engine
    }

    func set(_ newDemand: Demand?) {
        guard newDemand != demand else { return }
        demand = newDemand
        generation += 1
        token?.cancel()
        token = nil
        guard let newDemand else { return }
        let expected = generation
        Task { [engine] in
            let token = await engine.addDemand(newDemand)
            if expected == self.generation {
                self.token = token
            } else {
                token.cancel()
            }
        }
    }
}
