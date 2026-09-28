import SwiftUI

@main
struct TakelyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item, panel and windows are managed by AppDelegate; SwiftUI requires at least one scene.
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}
