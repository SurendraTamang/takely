@preconcurrency import AVFoundation
import AppCore
import AppKit
import Observation
@preconcurrency import ScreenCaptureKit

/// View state for the panel: displays, devices and permission status, over the controller, settings and coordinator.
@MainActor @Observable
final class RecorderModel {
    struct Display: Identifiable {
        let id: CGDirectDisplayID
        let name: String
    }

    struct Device: Identifiable {
        let id: String
        let name: String
    }

    let controller: RecordingController
    let settings: RecordingSettings
    let coordinator: RecordingCoordinator
    private(set) var displays: [Display] = []
    private(set) var microphones: [Device] = []
    private(set) var cameras: [Device] = []
    /// True when ScreenCaptureKit can't be reached, e.g. Screen Recording isn't granted.
    private(set) var screenPermissionDenied = false
    /// The hotkey hints, with the shortcuts as the person set them (refreshed when the panel opens).
    private(set) var setupHint = HotkeyHints.setup
    private(set) var recordingHint = HotkeyHints.recording

    init(controller: RecordingController, settings: RecordingSettings, coordinator: RecordingCoordinator) {
        self.controller = controller
        self.settings = settings
        self.coordinator = coordinator
    }

    /// Runs whenever the panel opens; never touches the controller's error, so it survives reopening.
    func refresh() async {
        setupHint = HotkeyHints.setup
        recordingHint = HotkeyHints.recording
        refreshDevices()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = Self.named(content.displays)
            if !displays.contains(where: { $0.id == settings.displayID }) {
                settings.displayID = displays.first?.id
            }
            screenPermissionDenied = false
        } catch {
            screenPermissionDenied = true
        }
    }

    private func refreshDevices() {
        func devices(_ types: [AVCaptureDevice.DeviceType], _ media: AVMediaType) -> [Device] {
            AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: media, position: .unspecified).devices
                .map { Device(id: $0.uniqueID, name: $0.localizedName) }
        }
        microphones = devices([.microphone], .audio)
        cameras = devices([.builtInWideAngleCamera, .external, .continuityCamera], .video)
    }

    /// Displays named like System Settings ("Built-in Retina Display"); identical names get " (2)", " (3)".
    private static func named(_ displays: [SCDisplay]) -> [Display] {
        let names = displays.map { display in
            NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }?
            .localizedName ?? "\(display.width) × \(display.height)"
        }
        var seen: [String: Int] = [:]
        return zip(displays, names).map { display, name in
            seen[name, default: 0] += 1
            let count = seen[name]!
            return Display(id: display.displayID, name: count == 1 ? name : "\(name) (\(count))")
        }
    }
}
