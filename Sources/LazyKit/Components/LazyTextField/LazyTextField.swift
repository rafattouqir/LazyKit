// Copyright (c) Rafat Touqir

import SwiftUI

/// Returns the value accepted from a text field after applying its character
/// limit. A nil or non-positive limit leaves the value unchanged.
internal func limitedText(_ value: String, characterLimit: Int?) -> String {
    guard let characterLimit, characterLimit > 0 else {
        return value
    }

    return String(value.prefix(characterLimit))
}

/// A multi-line text input that grows with its content and keeps a
/// placeholder visible while the bound text is empty.
///
/// A string placeholder uses the native `TextField` prompt. A custom
/// placeholder is an overlay, so its font and insets may need to be styled to
/// match the field on each platform. The field itself accepts the usual
/// SwiftUI modifiers.
///
/// The parent binding is the source of truth. A positive character limit is
/// applied to values received by the field, including user edits and
/// parent-driven updates.
///
/// ```swift
/// LazyTextField(text: $note, placeholder: "Write a note…")
///
/// LazyTextField(configuration: configuration, text: $note) {
///     Text("Write a note…").foregroundStyle(.blue)
/// }
/// ```
///
public struct LazyTextField<Placeholder: View>: View {
    /// The configuration type used by every `LazyTextField` specialization.
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
            // Correct after the binding update so the native editor receives
            // the accepted value without a local text buffer or feedback loop.
            .task(id: text) {
                let acceptedValue = limitedText(text, characterLimit: configuration.characterLimit)

                guard text != acceptedValue else {
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

    /// The line range the field grows within. A closed range caps growth:
    /// past the maximum, the field scrolls internally instead of growing.
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
