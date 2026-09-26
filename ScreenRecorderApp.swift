import SwiftUI

@main
struct ScreenRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(Color.clear)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
    }
}
