import SwiftUI
struct V: View {
    @State private var s = ""
    var body: some View {
        VStack {
            TextField("a", text: $s).textFieldStyle(.roundedBorder)
            TextField("b", text: $s).textFieldStyle(.squareBorder)
        }
    }
}
struct V_Previews: PreviewProvider { static var previews: some View { V().previewDisplayName("x") } }
