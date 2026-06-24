import SwiftUI
import Testing

@testable import LazyKit

struct LazyButtonTests {
    @Test("default configuration exposes the documented timing baseline")
    func defaultConfigurationHasExpectedTimingValues() {
        let configuration = LazyButtonConfiguration.default

        #expect(configuration.showLoaderAfter == .milliseconds(150))
        #expect(configuration.minimumLoaderDuration == .milliseconds(500))
        #expect(configuration.loaderColor == .white)
        #expect(configuration.accessibilityIdentifier == "lazy_button")
        #expect(configuration.loaderAccessibilityIdentifier == "lazy_button_loader")
    }

    @Test("configuration values can be customized")
    func configurationCanBeCustomized() {
        var configuration = LazyButtonConfiguration.default
        configuration.showLoaderAfter = .milliseconds(100)
        configuration.minimumLoaderDuration = .seconds(1)
        configuration.loaderColor = .orange
        configuration.accessibilityIdentifier = "custom_button"

        #expect(configuration.showLoaderAfter == .milliseconds(100))
        #expect(configuration.minimumLoaderDuration == .seconds(1))
        #expect(configuration.loaderColor == .orange)
        #expect(configuration.accessibilityIdentifier == "custom_button")
    }

    @Test("run IDs are claimed only once, so a reappearing view never re-runs")
    @MainActor func runIDsClaimedOnce() {
        let model = LazyButtonModel()

        #expect(model.claimCurrentRun() == nil)

        model.handleTap()
        #expect(model.claimCurrentRun() == 1)
        #expect(model.claimCurrentRun() == nil)

        model.handleTap()
        #expect(model.claimCurrentRun() == 2)
    }

    @Test("a run in flight ignores further taps and stays claimed")
    @MainActor func tapsIgnoredWhileBusy() async {
        let model = LazyButtonModel()
        model.handleTap()
        #expect(model.runID == 1)

        let task = Task {
            await model.execute(
                action: { try? await Task.sleep(for: .milliseconds(400)) },
                showLoaderAfter: .milliseconds(50),
                minimumLoaderDuration: .milliseconds(50),
                animation: .default
            )
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(model.isBusy)
        // The in-flight run holds the claim, so nothing can re-enter it.
        #expect(model.claimCurrentRun() == nil)

        // The tap lands mid-run, so it is ignored.
        model.handleTap()
        #expect(model.runID == 1)

        await task.value
        #expect(!model.isBusy)
        #expect(!model.loaderVisible)
    }

    @Test("cancelling the run task resets the model to idle")
    @MainActor func cancelledRunResetsToIdle() async {
        let model = LazyButtonModel()
        model.handleTap()

        let task = Task {
            // The same composition the view uses, so cancellation propagates.
            await model.execute(
                action: { try? await Task.sleep(for: .milliseconds(500)) },
                showLoaderAfter: .milliseconds(50),
                minimumLoaderDuration: .milliseconds(500),
                animation: .default
            )
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(model.loaderVisible)

        task.cancel()
        await task.value
        #expect(!model.isBusy)
        #expect(!model.loaderVisible)
    }
}
