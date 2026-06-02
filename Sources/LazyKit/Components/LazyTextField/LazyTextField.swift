// Copyright (c) Rafat Touqir

import SwiftUI

/// A multi-line text input that grows with its content and keeps a
/// placeholder visible while the bound text is empty.
///
/// The parent binding is the source of truth; a positive `characterLimit`
/// clamps every value the field receives, including user edits and
/// parent-driven updates. A string placeholder uses the native prompt, while
/// a custom placeholder is an overlay whose font and insets may need to match
/// the field per platform.
///
/// ```swift
/// LazyTextField(text: $note, placeholder: "Write a note…")
/// ```
///
public struct LazyTextField<Placeholder: View>: View {
    /// The configuration type used by this field.
    public typealias Configuration = LazyTextFieldConfiguration

    @Binding private var text: String
    private let configuration: Configuration
    private let prompt: Text?
    private let placeholder: Placeholder

    public init(
        configuration: Configuration = .default,
        text: Binding<String>,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.configuration = configuration
        self._text = text
        self.prompt = nil
        self.placeholder = placeholder()
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            textField

            if text.isEmpty {
                placeholderView
            }
        }
    }

    // MARK: - Subviews

    private var textField: some View {
        TextField("", text: $text, prompt: prompt, axis: .vertical)
            .lineLimit(lineLimit)
            // Clamp in the update that applies the edit: a deferred correction
            // would let the native editor stack further keystrokes on the
            // clamped value, which nothing would remove again.
            .onChange(of: text) { _, newValue in
                let acceptedValue = Self.limitedText(
                    newValue,
                    characterLimit: configuration.characterLimit
                )

                guard acceptedValue != newValue else {
                    return
                }

                text = acceptedValue
            }
            .accessibilityIdentifier(configuration.accessibilityIdentifier)
    }

    // MARK: - Derived values

    private var placeholderView: some View {
        placeholder
            .allowsHitTesting(false)
            .accessibilityIdentifier(configuration.placeholderAccessibilityIdentifier)
    }

    /// The line range the field grows within. Past the maximum the field
    /// scrolls internally instead of growing.
    private var lineLimit: ClosedRange<Int> {
        let minimum = max(1, configuration.minimumNumberOfLines)
        let maximum = max(minimum, configuration.maximumNumberOfLines ?? .max)
        return minimum...maximum
    }
}

extension LazyTextField where Placeholder == EmptyView {
    /// Creates a field whose string placeholder is the text field's native
    /// prompt.
    public init(
        configuration: Configuration = .default,
        text: Binding<String>,
        placeholder: String? = nil
    ) {
        self.configuration = configuration
        self._text = text
        self.prompt = placeholder.map { Text($0) }
        self.placeholder = EmptyView()
    }
}

extension LazyTextField {
    /// Applies the character limit to a value; a nil or non-positive limit
    /// leaves it unchanged.
    static func limitedText(_ value: String, characterLimit: Int?) -> String {
        guard let characterLimit, characterLimit > 0 else {
            return value
        }

        return String(value.prefix(characterLimit))
    }
}

#Preview("LazyTextField") {
    @Previewable @State var note = ""

    LazyTextField(text: $note, placeholder: "Write a note…")
        .padding()
}

#Preview("LazyTextField with a line and character limit") {
    @Previewable @State var note = ""

    LazyTextField(
        configuration: LazyTextFieldConfiguration(
            minimumNumberOfLines: 3,
            characterLimit: 200
        ),
        text: $note
    ) {
        Text("Write a note…")
            .foregroundStyle(.blue)
    }
    .padding()
}
