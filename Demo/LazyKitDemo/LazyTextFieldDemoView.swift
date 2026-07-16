import LazyKit
import SwiftUI

struct LazyTextFieldDemoView: View {
    fileprivate enum Field {
        case basic
        case populated
        case maxLines
        case customized
        case limited
    }

    @FocusState private var focusedField: Field?

    private var multilineConfiguration: LazyTextFieldConfiguration {
        LazyTextFieldConfiguration(minimumNumberOfLines: 2)
    }

    private var maxLinesConfiguration: LazyTextFieldConfiguration {
        .maxLinesDemo
    }

    private var customizedConfiguration: LazyTextFieldConfiguration {
        LazyTextFieldConfiguration(
            minimumNumberOfLines: 3,
            accessibilityIdentifier: "lazy_text_field_custom",
            placeholderAccessibilityIdentifier: "lazy_text_field_placeholder_custom"
        )
    }

    private var limitedConfiguration: LazyTextFieldConfiguration {
        LazyTextFieldConfiguration(
            characterLimit: 20,
            accessibilityIdentifier: "lazy_text_field_limited"
        )
    }

    var body: some View {
        List {
            DemoSection(
                title: "Basic placeholder",
                initialText: "",
                field: .basic,
                focused: $focusedField,
                showsCounter: false
            ) { text in
                LazyTextField(
                    text: text,
                    placeholder: "Start typing…"
                )
                .textFieldStyle(.roundedBorder)
            }

            DemoSection(
                title: "Growing multi-line content",
                initialText: "This field starts with multiple lines.\nKeep typing to see it grow.",
                field: .populated,
                focused: $focusedField,
                showsCounter: false
            ) { text in
                LazyTextField(
                    configuration: multilineConfiguration,
                    text: text,
                    placeholder: "Add more detail…"
                )
                .demoTextField()
            }

            DemoSection(
                title: "Maximum lines",
                initialText: "Type here — this field stops growing at four lines.",
                field: .maxLines,
                focused: $focusedField,
                showsCounter: false
            ) { text in
                LazyTextField(
                    configuration: maxLinesConfiguration,
                    text: text,
                    placeholder: "Up to four lines…"
                )
                .demoTextField()
            }

            DemoSection(
                title: "Custom placeholder",
                initialText: "",
                field: .customized,
                focused: $focusedField,
                showsCounter: false
            ) { text in
                LazyTextField(
                    configuration: customizedConfiguration,
                    text: text,
                    placeholder: {
                        Text("Customize the appearance…")
                            .foregroundStyle(.orange)
                    }
                )
                .demoTextField(
                    background: Color.orange.opacity(0.08),
                    border: .orange,
                    cornerRadius: 14
                )
            }

            DemoSection(
                title: "Character limit",
                initialText: "",
                field: .limited,
                focused: $focusedField,
                showsCounter: true
            ) { text in
                LazyTextField(
                    configuration: limitedConfiguration,
                    text: text
                )
                .demoTextField()
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if focusedField != nil {
                HStack {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("LazyTextField")
    }
}

private struct DemoSection<Content: View>: View {
    let title: LocalizedStringKey
    let field: LazyTextFieldDemoView.Field
    var focused: FocusState<LazyTextFieldDemoView.Field?>.Binding
    let showsCounter: Bool
    @ViewBuilder let content: (Binding<String>) -> Content

    @State private var text: String

    init(
        title: LocalizedStringKey,
        initialText: String,
        field: LazyTextFieldDemoView.Field,
        focused: FocusState<LazyTextFieldDemoView.Field?>.Binding,
        showsCounter: Bool,
        @ViewBuilder content: @escaping (Binding<String>) -> Content
    ) {
        self.title = title
        self.field = field
        self.focused = focused
        self.showsCounter = showsCounter
        self.content = content
        self._text = State(initialValue: initialText)
    }

    var body: some View {
        Section {
            content($text)
                .focused(focused, equals: field)

            if showsCounter {
                CharacterLimitFooter(current: text.count, limit: 20)
            }
        } header: {
            Text(title)
        }
    }
}

private struct CharacterLimitFooter: View {
    let current: Int
    let limit: Int

    var body: some View {
        HStack {
            Text("Maximum \(limit) characters")
            Spacer()
            Text("\(current)/\(limit)")
                .accessibilityIdentifier("limited_character_count")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Grows from one line up to four, then scrolls internally.
extension LazyTextFieldConfiguration {
    fileprivate static var maxLinesDemo: Self {
        var configuration: Self = .default
        configuration.minimumNumberOfLines = 1
        configuration.maximumNumberOfLines = 4
        configuration.accessibilityIdentifier = "lazy_text_field_max_lines"
        configuration.placeholderAccessibilityIdentifier = "lazy_text_field_placeholder_max_lines"
        return configuration
    }
}

private extension View {
    func demoTextField(
        background: Color = .clear,
        border: Color = Color.secondary.opacity(0.35),
        cornerRadius: CGFloat = 8
    ) -> some View {
        font(.body)
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(border, lineWidth: 1)
            }
    }
}

#Preview("Maximum lines") {
    @Previewable @State var text = (1...8).map { "Preview line \($0)" }.joined(separator: "\n")

    NavigationStack {
        LazyTextField(
            configuration: .maxLinesDemo,
            text: $text,
            placeholder: "Preview placeholder…"
        )
        .padding()
        .navigationTitle("Maximum lines")
    }
}

#Preview("Empty") {
    NavigationStack {
        LazyTextFieldDemoView()
    }
}

#Preview("Populated") {
    @Previewable @State var text = "A populated preview\nwith multiple lines"

    NavigationStack {
        LazyTextField(
            text: $text,
            placeholder: "Preview placeholder…"
        )
        .padding()
        .navigationTitle("LazyTextField")
    }
}
