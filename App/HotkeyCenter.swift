import AppCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", initial: .init(.r, modifiers: [.option, .shift]))
    static let togglePause = Self("togglePause", initial: .init(.p, modifiers: [.option, .shift]))
    static let togglePanel = Self("togglePanel", initial: .init(.t, modifiers: [.option, .shift]))
    static let toggleCamera = Self("toggleCamera", initial: .init(.c, modifiers: [.option, .shift]))
    static let togglePrompter = Self("togglePrompter", initial: .init(.s, modifiers: [.option, .shift]))
    static let retake = Self("retake", initial: .init(.z, modifiers: [.option, .shift]))
    static let addMarker = Self("addMarker", initial: .init(.m, modifiers: [.option, .shift]))
    static let toggleDrawing = Self("toggleDrawing", initial: .init(.d, modifiers: [.option, .shift]))
}

/// Global hotkeys: ⌥⇧R start/stop (skips a running countdown), ⌥⇧P pause/resume, ⌥⇧T show/hide the panel,
/// ⌥⇧C show/hide the camera, ⌥⇧S show/hide the prompter; while recording also ⌥⇧Z retake, ⌥⇧M marker,
/// ⌥⇧D draw (rebindable in Settings). They go through the same commands as the panel buttons.
@MainActor
enum HotkeyCenter {
    static func install(controller: RecordingController, coordinator: RecordingCoordinator, statusItem: StatusItemController) {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            Task { await coordinator.toggleRecording() }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleCamera) {
            coordinator.toggleBubble()
        }
        KeyboardShortcuts.onKeyUp(for: .togglePrompter) {
            coordinator.togglePrompter()
        }
        KeyboardShortcuts.onKeyUp(for: .retake) {
            Task { await coordinator.retake() }
        }
        KeyboardShortcuts.onKeyUp(for: .addMarker) {
            coordinator.addMarker()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleDrawing) {
            coordinator.toggleDrawing()
        }
        KeyboardShortcuts.onKeyUp(for: .togglePause) {
            Task { await controller.togglePause() }
        }
        KeyboardShortcuts.onKeyUp(for: .togglePanel) {
            statusItem.togglePanel()
        }
    }
}

/// The panel's and welcome window's shortcut hints, from the shortcuts actually set (they're rebindable).
@MainActor
enum HotkeyHints {
    static func key(_ name: KeyboardShortcuts.Name) -> String? { KeyboardShortcuts.getShortcut(for: name)?.description }

    static func join(_ items: [(KeyboardShortcuts.Name, String)]) -> String {
        items.compactMap { name, what in key(name).map { "\($0) \(what)" } }.joined(separator: " · ")
    }

    static var setup: String {
        join([
            (.toggleRecording, "records from anywhere"), (.togglePanel, "opens this panel"), (.toggleCamera, "camera"),
            (.togglePrompter, "prompter"),
        ])
    }

    static var recording: String { join([(.retake, "oops, retake"), (.addMarker, "marker"), (.toggleDrawing, "draw on screen")]) }
}
