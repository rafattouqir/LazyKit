// Copyright (c) Rafat Touqir

import SwiftUI

/// A button that runs an async action and shows a loader while that work runs.
///
/// The action runs in a task tied to the view's lifecycle, and taps are
/// ignored while the action, or the loader it raised, is still active. The
/// action handles its own errors; cancellation is cooperative, so the button
/// resets once the action returns.
///
/// The loader appears only if the action outlasts
/// `Configuration.showLoaderAfter` and stays visible for
/// `Configuration.minimumLoaderDuration`. Pass a custom loader as a view
/// builder, or use the built-in spinner tinted with
/// `Configuration.loaderColor`:
///
/// ```swift
/// LazyButton("Save") {
///     try? await api.save()
/// }
/// ```
///
public struct LazyButton<Label: View, Loader: View>: View {
    /// The configuration type used by this button.
    public typealias Configuration = LazyButtonConfiguration

    private let configuration: Configuration
    private let label: Label
    private let loader: Loader
    private let action: @MainActor () async -> Void

    @State private var model = LazyButtonModel()

    public init(
        configuration: Configuration = .default,
        @ViewBuilder label: () -> Label,
        @ViewBuilder loader: () -> Loader,
        action: @escaping @MainActor () async -> Void
    ) {
        self.configuration = configuration
        self.label = label()
        self.loader = loader()
        self.action = action
    }

    public var body: some View {
        Button(action: model.handleTap) {
            label
                // Keep the label's layout while the loader is visible.
                .opacity(model.loaderVisible ? 0 : 1)
                .accessibilityHidden(model.loaderVisible)
                .overlay {
                    if model.loaderVisible {
                        loaderView
                    }
                }
        }
        .disabled(model.isBusy)
        .opacity(model.isBusy ? 0.6 : 1)
        .animation(.easeOut(duration: 0.15), value: model.isBusy)
        .accessibilityIdentifier(configuration.accessibilityIdentifier)
        .task(id: model.runID) {
            await model.execute(
                action: action,
                showLoaderAfter: configuration.showLoaderAfter,
                minimumLoaderDuration: configuration.minimumLoaderDuration,
                animation: configuration.loaderAnimation
            )
        }
    }

    // MARK: - Subviews

    private var loaderView: some View {
        loader
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(configuration.loaderAccessibilityIdentifier)
            .accessibilityLabel("Loading")
    }

}

// MARK: - Default loader

/// The built-in spinner loader used when no custom loader is provided.
public struct LazyButtonDefaultLoader: View {
    private let loaderColor: Color

    public init(loaderColor: Color) {
        self.loaderColor = loaderColor
    }

    public var body: some View {
        ProgressView()
            .tint(loaderColor)
    }
}

extension LazyButton where Loader == LazyButtonDefaultLoader {
    /// Creates a button with the built-in spinner loader.
    public init(
        configuration: Configuration = .default,
        @ViewBuilder label: () -> Label,
        action: @escaping @MainActor () async -> Void
    ) {
        self.init(
            configuration: configuration,
            label: label,
            loader: { LazyButtonDefaultLoader(loaderColor: configuration.loaderColor) },
            action: action
        )
    }
}

extension LazyButton where Label == Text, Loader == LazyButtonDefaultLoader {
    /// Creates a button with a text label and the built-in spinner loader.
    public init(
        _ titleKey: LocalizedStringKey,
        configuration: Configuration = .default,
        action: @escaping @MainActor () async -> Void
    ) {
        self.init(
            configuration: configuration,
            label: { Text(titleKey) },
            action: action
        )
    }
}

extension LazyButton where Label == Text {
    /// Creates a button with a text label and a custom loader.
    public init(
        _ titleKey: LocalizedStringKey,
        configuration: Configuration = .default,
        @ViewBuilder loader: () -> Loader,
        action: @escaping @MainActor () async -> Void
    ) {
        self.init(
            configuration: configuration,
            label: { Text(titleKey) },
            loader: loader,
            action: action
        )
    }
}

#Preview("LazyButton") {
    LazyButton("Save") {
        try? await Task.sleep(for: .seconds(2))
    }
    .buttonStyle(.borderedProminent)
    .padding()
}

#Preview("LazyButton with a custom loader") {
    LazyButton(
        "Publish",
        loader: {
            Image(systemName: "circle.dotted")
                .foregroundStyle(.white)
        }
    ) {
        try? await Task.sleep(for: .seconds(2))
    }
    .font(.body.weight(.semibold))
    .foregroundStyle(.white)
    .padding()
    .background(.indigo)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .padding()
}
