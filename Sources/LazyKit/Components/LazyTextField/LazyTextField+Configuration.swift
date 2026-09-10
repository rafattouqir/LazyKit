// Copyright (c) Rafat Touqir

import SwiftUI

/// Input behavior and accessibility options for a `LazyTextField`.
///
/// The field's appearance is styled with ordinary SwiftUI modifiers. Copy
/// `LazyTextFieldConfiguration.default` and change only the values you need:
///
/// ```swift
/// var configuration = LazyTextFieldConfiguration.default
/// configuration.minimumNumberOfLines = 3
/// configuration.characterLimit = 200
/// ```
public struct LazyTextFieldConfiguration {
    /// The minimum number of lines the field reserves. Values below 1 are
    /// treated as 1.
    public var minimumNumberOfLines: Int

    /// The maximum number of lines the field grows to, or `nil` for no
    /// limit. Once the content exceeds this many lines, the field stops
    /// growing and scrolls internally instead. Values below
    /// `minimumNumberOfLines` are treated as `minimumNumberOfLines`.
    public var maximumNumberOfLines: Int?

    /// The maximum number of characters accepted, or `nil` for no limit.
    /// Input beyond the limit is clamped; the component shows no toast or
    /// error message, so consumers render their own counter or validation
    /// UI. A non-positive value means "no limit".
    public var characterLimit: Int?

    /// The accessibility identifier applied to the text field itself.
    public var accessibilityIdentifier: String

    /// The accessibility identifier applied to a custom placeholder while
    /// visible. The built-in string placeholder is rendered as the field's
    /// native prompt instead, so UI tests observe it through the field's
    /// placeholder value.
    public var placeholderAccessibilityIdentifier: String

    public init(
        minimumNumberOfLines: Int = 1,
        maximumNumberOfLines: Int? = nil,
        characterLimit: Int? = nil,
        accessibilityIdentifier: String = "lazy_text_field",
        placeholderAccessibilityIdentifier: String = "lazy_text_field_placeholder"
    ) {
        self.minimumNumberOfLines = minimumNumberOfLines
        self.maximumNumberOfLines = maximumNumberOfLines
        self.characterLimit = characterLimit
        self.accessibilityIdentifier = accessibilityIdentifier
        self.placeholderAccessibilityIdentifier = placeholderAccessibilityIdentifier
    }

    /// The standard behavior: one reserved line, uncapped growth, and no
    /// character limit.
    public static var `default`: LazyTextFieldConfiguration {
        LazyTextFieldConfiguration()
    }
}
