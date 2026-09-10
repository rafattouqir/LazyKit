import LazyKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    LazyTextFieldDemoView()
                } label: {
                    Label("Text Field", systemImage: "text.alignleft")
                }
                .accessibilityIdentifier("component_lazy_text_field")

                NavigationLink {
                    LazyButtonDemoView()
                } label: {
                    Label("Button", systemImage: "button.programmable")
                }
                .accessibilityIdentifier("component_lazy_button")
            }
            .navigationTitle("LazyKit")
        }
    }
}

#Preview("Components") {
    ContentView()
}
