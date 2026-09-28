import SwiftUI
import Observation

@Observable final class Model {
    var cpu: Double = 0
    init() { print("Model.init") }
}

struct Probe: View {
    @State private var model = Model()
    @State private var count: Int = 0
    var body: some View {
        Text("\(model.cpu) \(count)")
    }
}
