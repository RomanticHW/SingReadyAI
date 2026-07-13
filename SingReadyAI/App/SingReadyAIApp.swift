import SwiftUI
import SingReadyAISharedKit

@main
struct SingReadyAIApp: App {
    @StateObject private var store = DemoWorkflowStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
