import SwiftUI

@main
struct AppleMusicPresenceLocalApp: App {
    @State private var coordinator = PresenceCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(coordinator)
                .task { await coordinator.bootstrap() }
        }
    }
}
