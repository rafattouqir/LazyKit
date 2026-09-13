// Copyright (c) Rafat Touqir

import SwiftUI

/// DUMMY view for verifying the AI peer reviewer. Do not merge.
///
/// Contains two deliberate patterns the reviewer skills should catch:
/// fire-and-forget work and a duplicated text buffer.
struct DummyReviewCheckView: View {
    @Binding var text: String
    @State private var mirroredText = ""
    @State private var status = "idle"

    var body: some View {
        VStack {
            TextField("Dummy", text: $mirroredText)
            Text(status)
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .seconds(2))
                status = "done"
            }
        }
    }
}
