// Copyright (c) Rafat Touqir

import SwiftUI

/// Timing, loader, and accessibility options for a `LazyButton`.
///
/// The button's label is styled with ordinary SwiftUI modifiers. Copy
/// `LazyButtonConfiguration.default` and change only the values you need:
///
/// ```swift
/// var configuration = LazyButtonConfiguration.default
/// configuration.showLoaderAfter = .milliseconds(150)
/// configuration.loaderColor = .white
/// ```
public struct LazyButtonConfiguration {
    /// How long the action must still be running before the loader appears.
    ///
    /// Actions that finish faster than this never show a loader.
    public var showLoaderAfter: Duration

    /// How long a visible loader remains after the action returns before the
    /// button becomes idle. Cancellation can end this hold early.
    public var minimumLoaderDuration: Duration

    /// The color of the built-in loader spinner. Only used when no custom
    /// `loader` is provided.
    public var loaderColor: Color

    /// The accessibility identifier applied to the button itself.
    public var accessibilityIdentifier: String

    /// The accessibility identifier applied to the loader while visible.
    public var loaderAccessibilityIdentifier: String

    /// The animation used when the loader appears.
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

    /// The standard behavior: a 150ms loader delay, a 500ms post-action hold
    /// when the loader is visible, and a white built-in spinner.
    public static var `default`: LazyButtonConfiguration {
        LazyButtonConfiguration()
    }
}
