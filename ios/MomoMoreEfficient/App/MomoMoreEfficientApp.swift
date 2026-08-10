import SwiftUI

@main
struct MomoMoreEfficientApp: App {
    var body: some Scene {
        WindowGroup {
            // The real view model, unless a DEBUG build was explicitly launched in
            // rehearsal mode. See `RehearsalMode`.
            ContentView(viewModel: CompanionViewModel.makeDefault())
        }
    }
}
