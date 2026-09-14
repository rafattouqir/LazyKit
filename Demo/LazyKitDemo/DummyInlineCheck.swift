// Copyright (c) Rafat Touqir

import SwiftUI

/// DUMMY view for verifying inline PR review threads. Do not merge.
struct DummyInlineCheckView: View {
    @Binding var text: String
    @State private var mirroredText = ""

    var body: some View {
        TextField("Dummy", text: $mirroredText)
    }
}
