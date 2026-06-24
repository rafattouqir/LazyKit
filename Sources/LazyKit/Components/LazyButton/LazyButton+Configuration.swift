// Copyright (c) Rafat Touqir

import SwiftUI

/// Timing, loader, and accessibility options for a `LazyButton`.
///
/// Start from `.default` and change only the values you need:
///
/// ```swift
/// var configuration = LazyButtonConfiguration.default
/// configuration.showLoaderAfter = .milliseconds(150)
/// configuration.loaderColor = .white
/// ```
public struct LazyButtonConfiguration {
    /// How long the action must still run before the loader appears; actions
    /// that finish sooner never show one.
    public var showLoaderAfter: Duration

    /// How long a visible loader stays up after the action returns.
    public var minimumLoaderDuration: Duration

    /// Tint of the built-in spinner; ignored when a custom loader is passed.
    public var loaderColor: Color

    /// Accessibility identifier applied to the button.
    public var accessibilityIdentifier: String

    /// Accessibility identifier applied to the loader while it is visible.
    public var loaderAccessibilityIdentifier: String

    /// Animation used when the loader appears.
    public var loaderAnimation: Animation

    public init(
        showLoaderAfter: Duration = .milliseconds(150),
        minimumLoaderDuration: Duration = .milliseconds(500),
        loaderColor: Color = .white,
        accessibilityIdentifier: String = "lazy_button",
        loaderAccessibilityIdentifier: String = "lazy_button_loader",
        loaderAnimation: Animation = .smooth(duration: 0.2)
    ) {
        self.showLoaderAfter = showLoaderAfter
        self.minimumLoaderDuration = minimumLoaderDuration
        self.loaderColor = loaderColor
        self.accessibilityIdentifier = accessibilityIdentifier
        self.loaderAccessibilityIdentifier = loaderAccessibilityIdentifier
        self.loaderAnimation = loaderAnimation
    }

    /// The standard behavior: a 150 ms loader delay, a 500 ms hold, and a white
    /// built-in spinner.
    public static var `default`: LazyButtonConfiguration {
        LazyButtonConfiguration()
    }
}
