import Foundation
import Observation

@MainActor @Observable final class Metrics {
    var cpu: Double = 0
    var label: String = "idle"
}

@MainActor var log: [String] = []

@main struct Main {
    @MainActor static func main() async {
        let m = Metrics()

        // A) classic one-shot tracking + equal-value dedupe (Observable macro shouldNotifyObservers)
        var fired = 0
        withObservationTracking { _ = m.cpu } onChange: { MainActor.assumeIsolated { fired += 1 } }
        m.cpu = 0          // equal value
        print("A: after equal-value set, one-shot onChange fired =", fired)
        m.cpu = 1
        print("A: after changed-value set, one-shot onChange fired =", fired)

        // B) macOS 27: continuous observation
        var n = 0
        let token = withContinuousObservation(options: [.didSet]) { event in
            let k: String
            switch event.kind {
            case .initial: k = "initial"
            case .willSet: k = "willSet"
            case .didSet:  k = "didSet"
            default:       k = "other"
            }
            MainActor.assumeIsolated {
                n += 1
                log.append("\(k) cpu=\(m.cpu) matchesCPU=\(event.matches(\Metrics.cpu))")
            }
        }
        for v in [2.0, 2.0, 3.0, 4.0] {
            m.cpu = v
            try? await Task.sleep(for: .milliseconds(30))
        }
        m.label = "busy"      // not read inside apply -> should not fire
        try? await Task.sleep(for: .milliseconds(30))
        token.cancel()
        m.cpu = 99
        try? await Task.sleep(for: .milliseconds(30))
        print("B: continuous events =", n)
        for l in log { print("   ", l) }
    }
}
