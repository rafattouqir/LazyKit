// Copyright (c) Rafat Touqir

import SwiftUI

/// A button whose action is asynchronous and whose loading state follows that
/// work.
///
/// The action runs in a task tied to the view's lifecycle. The button ignores
/// taps while the action or its loader hold is active. If the view disappears,
/// the task is cancelled cooperatively; state returns to idle after the action
/// returns. Reappearing does not re-run the last tap.
///
/// The loader appears only while the action is still running after
/// `Configuration.showLoaderAfter`. If it is visible when the action returns,
/// it remains visible for `Configuration.minimumLoaderDuration` after that
/// return before the button becomes idle. The action handles its own errors.
///
/// The label is rendered untouched, so it can be styled with the usual
/// SwiftUI modifiers. `Configuration` contains loader timing, the built-in
/// spinner tint, its appearance animation, and accessibility identifiers.
///
/// Pass a custom loader as a view builder; otherwise the built-in spinner uses
/// `Configuration.loaderColor`:
///
/// ```swift
/// LazyButton("Save") {
///     try? await api.save()
/// }
///
/// LazyButton(
///     "Save",
///     configuration: configuration,
///     loader: {
///         Image(systemName: "circle.dotted")
///     }
/// ) {
///     try? await api.save()
/// }
/// ```
///
public struct LazyButton<Label: View, Loader: View>: View {
    /// The configuration type used by every `LazyButton` specialization.
    public typealias Configuration = LazyButtonConfiguration

    private let configuration: Configuration
    private let label: Label
    private let loader: Loader
    private let action: @MainActor () async -> Void

    @StateObject private var model = Model()

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
        Button(action: handleTap) {
            label
                // Preserve the label's layout while showing the loader.
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

    // MARK: - Actions

    private func handleTap() {
        guard !model.isBusy else { return }
        model.runID += 1
    }
}

// MARK: - Default loader

/// The built-in loader shown while a `LazyButton` is busy when no custom
/// loader is provided: a spinner tinted with the configuration's loader color.
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

// MARK: - State model

extension LazyButton {
    /// Owns loading state and the action lifecycle as a reference type so
    /// mutations from the running task remain visible to SwiftUI.
    @MainActor
    final class Model: ObservableObject {
        /// Incremented on each accepted tap; `.task(id:)` runs that action.
        @Published var runID = 0
        /// True while the action or post-action loader hold is active.
        @Published private(set) var isBusy = false
        /// True after the loader delay has elapsed for the current run.
        @Published private(set) var loaderVisible = false

        /// Run ID that owns shared state. Ownership checks keep superseded or
        /// refired tasks from mutating the current run.
        private var launchedRunID = 0

        /// Claims the current run once. A reappearing view can restart
        /// `.task(id:)`, so this guard prevents an already claimed ID from
        /// running again without a new tap.
        func claimCurrentRun() -> Int? {
            let id = runID
            guard id > 0, id != launchedRunID else { return nil }
            launchedRunID = id
            return id
        }

        /// Shows the loader after `delay` if this run still owns the state.
        /// It is a child of the view task, and ownership checks cover actions
        /// that outlive cancellation.
        private func fireLoaderAfterDelay(id: Int, after delay: Duration, animation: Animation) async {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard id == launchedRunID, id == runID, isBusy else { return }
            withAnimation(animation) {
                loaderVisible = true
            }
        }

        /// Runs the action and loader lifecycle in the caller's task. The
        /// delay is a child task, while the action and post-action hold run
        /// inline so cancellation propagates through the view task.
        func execute(
            action: @escaping @MainActor () async -> Void,
            showLoaderAfter: Duration,
            minimumLoaderDuration: Duration,
            animation: Animation
        ) async {
            guard let id = claimCurrentRun() else { return }
            await withDiscardingTaskGroup { group in
                group.addTask {
                    await self.fireLoaderAfterDelay(id: id, after: showLoaderAfter, animation: animation)
                }
                await self.run(
                    id: id,
                    action: action,
                    minimumLoaderDuration: minimumLoaderDuration
                )
                group.cancelAll()
            }
        }

        func run(
            id: Int,
            action: @escaping @MainActor () async -> Void,
            minimumLoaderDuration: Duration
        ) async {
            // Only the claimed, current run owns the shared state.
            guard !Task.isCancelled, id == launchedRunID, id == runID else { return }

            isBusy = true
            loaderVisible = false

            await action()

            // Cancellation is cooperative: the action must return before the
            // model can reset. A superseded run leaves the current run alone.
            guard id == launchedRunID, id == runID else { return }
            if Task.isCancelled {
                loaderVisible = false
                isBusy = false
                return
            }

            if loaderVisible {
                // Hold a visible loader after action completion. This inline
                // sleep is cancelled with the view task.
                try? await Task.sleep(for: minimumLoaderDuration)
                guard id == launchedRunID, id == runID else { return }
            }

            loaderVisible = false
            isBusy = false
        }
    }
}
