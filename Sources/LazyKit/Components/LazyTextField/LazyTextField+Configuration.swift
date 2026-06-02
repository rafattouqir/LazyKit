// Copyright (c) Rafat Touqir

import SwiftUI

/// Input behavior and accessibility options for a `LazyTextField`.
///
/// Start from `.default` and change only the values you need:
///
/// ```swift
/// var configuration = LazyTextFieldConfiguration.default
/// configuration.minimumNumberOfLines = 3
/// configuration.characterLimit = 200
/// ```
public struct LazyTextFieldConfiguration {
    /// Minimum number of lines the field reserves; values below 1 are treated
    /// as 1.
    public var minimumNumberOfLines: Int

    /// Maximum number of lines the field grows to, or `nil` for no limit. Past
    /// it the field scrolls internally. Values below `minimumNumberOfLines`
    /// are treated as the minimum.
    public var maximumNumberOfLines: Int?

    /// Maximum number of characters accepted, or `nil` for no limit. Input
    /// beyond the limit is clamped; the field renders no counter or error UI
    /// of its own.
    public var characterLimit: Int?

    /// Accessibility identifier applied to the text field.
    public var accessibilityIdentifier: String

    /// Accessibility identifier applied to a custom placeholder while visible.
    /// A string placeholder renders as the field's native prompt instead, so
    /// UI tests observe it through the field's placeholder value.
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

    /// The standard behavior: one reserved line, uncapped growth, and no limit.
    public static var `default`: LazyTextFieldConfiguration {
        LazyTextFieldConfiguration()
    }
}
