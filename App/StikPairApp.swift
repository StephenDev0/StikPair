import SwiftUI

@main
struct StikPairApp: App {
    init() {
        PairingController.shared.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
