import AppCore
import Observation
@preconcurrency import ScreenCaptureKit

/// View state for the panel: the display list and permission status, over the controller and settings.
@MainActor @Observable
final class RecorderModel {
    let controller: RecordingController
    let settings: RecordingSettings
    private(set) var displays: [SCDisplay] = []
    /// True when ScreenCaptureKit can't be reached, e.g. Screen Recording isn't granted.
    private(set) var screenPermissionDenied = false

    init(controller: RecordingController, settings: RecordingSettings) {
        self.controller = controller
        self.settings = settings
    }

    /// Runs whenever the panel opens; never touches the controller's error, so it survives reopening.
    func refreshDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = content.displays
            if !displays.contains(where: { $0.displayID == settings.displayID }) {
                settings.displayID = displays.first?.displayID
            }
            screenPermissionDenied = false
        } catch {
            screenPermissionDenied = true
        }
    }
}
