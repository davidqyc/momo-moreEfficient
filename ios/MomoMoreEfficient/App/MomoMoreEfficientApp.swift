import SwiftUI

@main
struct MomoMoreEfficientApp: App {
    @StateObject private var captureReviewStore = CaptureReviewStore.shared

    init() {
        #if DEBUG
        CaptureUITestSeed.installIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // The real view model, unless a DEBUG build was explicitly launched in
            // rehearsal mode. See `RehearsalMode`.
            ContentView(
                viewModel: CompanionViewModel.makeDefault(),
                captureReviewStore: captureReviewStore
            )
        }
    }
}
