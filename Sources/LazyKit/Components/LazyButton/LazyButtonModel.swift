// Copyright (c) Rafat Touqir

import SwiftUI

/// Owns loading state and the action lifecycle as an observable reference type,
/// so mutations from the running task stay visible to SwiftUI.
///
/// Kept at file scope so it is not parameterized by the button's `Label` and
/// `Loader` generics.
@MainActor
@Observable
final class LazyButtonModel {
    /// Advanced on each accepted tap; `.task(id:)` runs the action for it.
    private(set) var runID = 0
    /// True while the action or post-action loader hold is active.
    private(set) var isBusy = false
    /// True once the loader delay has elapsed for the current run.
    private(set) var loaderVisible = false

    /// Run ID that owns the shared state. Bookkeeping only, never read by
    /// `body`, so it stays out of observation.
    @ObservationIgnored private var launchedRunID = 0

    /// Whether `id` is the claimed, current run allowed to mutate shared state.
    private func ownsSharedState(_ id: Int) -> Bool {
        id == launchedRunID && id == runID
    }

    /// Claims the current run once, so a reappearing view cannot re-run it
    /// without a new tap.
    func claimCurrentRun() -> Int? {
        let id = runID
        guard id > 0, id != launchedRunID else { return nil }
        launchedRunID = id
        return id
    }

    /// Accepts a tap and schedules a run, unless one is still active.
    func handleTap() {
        guard !isBusy else { return }
        runID += 1
    }

    /// Shows the loader after `delay` if this run still owns the state.
    private func fireLoaderAfterDelay(id: Int, after delay: Duration, animation: Animation) async {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        guard ownsSharedState(id), isBusy else { return }
        withAnimation(animation) {
            loaderVisible = true
        }
    }

    /// Runs the action and loader lifecycle in the caller's task. The delay is
    /// a child task, while the action and post-action hold run inline so
    /// cancellation propagates through the view task.
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

    private func run(
        id: Int,
        action: @escaping @MainActor () async -> Void,
        minimumLoaderDuration: Duration
    ) async {
        guard !Task.isCancelled, ownsSharedState(id) else { return }

        isBusy = true
        loaderVisible = false

        await action()

        // Cancellation is cooperative: the action must return before the state
        // resets, and a superseded run leaves the current run alone.
        guard ownsSharedState(id) else { return }

        // A cancelled run ends the hold early.
        if !Task.isCancelled, loaderVisible {
            try? await Task.sleep(for: minimumLoaderDuration)
            guard ownsSharedState(id) else { return }
        }

        loaderVisible = false
        isBusy = false
    }
}
