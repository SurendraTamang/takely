import AppCore
import AppKit
import OSLog
import ProjectKit
import RenderKit
import SwiftUI

/// Owns the app's objects and wires up the menu bar item and notifications.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = RecordingSettings()
    private let notifier = ReadyNotifier()
    private(set) lazy var controller = RecordingController(
        session: LiveRecordingSession(settings: settings),
        exporter: Exporter(),
        feedback: notifier,
        saveFolder: { [settings] in settings.saveFolder })
    private lazy var model = RecorderModel(controller: controller, settings: settings)
    private var statusItem: StatusItemController?
    private let log = Logger(subsystem: "app.takely", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.activate()
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
    }
}
