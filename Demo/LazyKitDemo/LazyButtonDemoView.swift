import LazyKit
import SwiftUI

struct LazyButtonDemoView: View {
    @State private var fastResult = "Tap to run a fast async action."
    @State private var slowResult = "Tap to run a slow async action."
    @State private var tintedResult = "Tap to run a tinted-loader task."
    @State private var customResult = "Tap to run a custom-loader task."

    private var fastConfiguration: LazyButtonConfiguration {
        LazyButtonConfiguration(accessibilityIdentifier: "lazy_button_fast")
    }

    private var slowConfiguration: LazyButtonConfiguration {
        LazyButtonConfiguration(accessibilityIdentifier: "lazy_button_slow")
    }

    private var tintedConfiguration: LazyButtonConfiguration {
        LazyButtonConfiguration(
            loaderColor: .white,
            accessibilityIdentifier: "lazy_button_tinted"
        )
    }

    private var customConfiguration: LazyButtonConfiguration {
        LazyButtonConfiguration(accessibilityIdentifier: "lazy_button_custom")
    }

    var body: some View {
        List {
            Section {
                LazyButton("Run fast task", configuration: fastConfiguration) {
                    try? await Task.sleep(for: .milliseconds(100))
                    fastResult = "Fast action completed."
                }
                .pillButton(background: .accentColor)
                .buttonStyle(PillButtonStyle(background: .accentColor))
                DemoCaption(text: fastResult, identifier: "lazy_button_fast_result")
            } header: {
                Text("Fast async action")
            }

            Section {
                LazyButton("Run slow task", configuration: slowConfiguration) {
                    try? await Task.sleep(for: .seconds(2))
                    slowResult = "Slow action completed."
                }
                .pillButton(background: .accentColor)
                DemoCaption(text: slowResult, identifier: "lazy_button_slow_result")
            } header: {
                Text("Slow async action")
            }

            Section {
                LazyButton("Run tinted task", configuration: tintedConfiguration) {
                    try? await Task.sleep(for: .seconds(2))
                    tintedResult = "Tinted loader shown."
                }
                .pillButton(background: .orange)
                DemoCaption(text: tintedResult, identifier: "lazy_button_tinted_result")
            } header: {
                Text("Custom loader color")
            }

            Section {
                LazyButton(
                    "Run custom loader",
                    configuration: customConfiguration,
                    loader: {
                        Image(systemName: "circle.dotted")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                ) {
                    try? await Task.sleep(for: .seconds(2))
                    customResult = "Custom loader shown."
                }
                .pillButton(background: .indigo)
                DemoCaption(text: customResult, identifier: "lazy_button_custom_result")
            } header: {
                Text("Custom loader view")
            }
        }
        .listStyle(.insetGrouped)
        .buttonStyle(.borderless)
        .navigationTitle("LazyButton")
    }
}

private struct DemoCaption: View {
    let text: String
    let identifier: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(identifier)
    }
}

private extension LazyButton {
    func pillButton(background: Color) -> some View {
        buttonStyle(PillButtonStyle(background: background))
    }
}

private struct PillButtonStyle: ButtonStyle {
    let background: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.white.opacity(configuration.isPressed ? 0.2 : 0))
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

#Preview("LazyButton") {
    NavigationStack {
        LazyButtonDemoView()
    }
}
