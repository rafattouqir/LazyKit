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
        let model = LazyButton<Text, LazyButtonDefaultLoader>.Model()

        #expect(model.claimCurrentRun() == nil)

        model.runID += 1
        #expect(model.claimCurrentRun() == 1)
        #expect(model.claimCurrentRun() == nil)

        model.runID += 1
        #expect(model.claimCurrentRun() == 2)
    }

    @Test("a superseded run leaves shared state untouched")
    @MainActor func supersededRunLeavesStateUntouched() async {
        let model = LazyButton<Text, LazyButtonDefaultLoader>.Model()
        model.runID += 1
        #expect(model.claimCurrentRun() == 1)
        model.runID += 1
        #expect(model.claimCurrentRun() == 2)

        await model.run(
            id: 1,
            action: {},
            minimumLoaderDuration: .milliseconds(500)
        )
        #expect(!model.isBusy)
        #expect(!model.loaderVisible)
    }

    @Test("cancelling the run task resets the model to idle")
    @MainActor func cancelledRunResetsToIdle() async {
        let model = LazyButton<Text, LazyButtonDefaultLoader>.Model()
        model.runID += 1

        let task = Task {
            // Same composition the view uses: `execute` structures the loader
            // delay into the task, so cancelling propagates to it.
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
