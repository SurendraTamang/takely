import AppCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", initial: .init(.r, modifiers: [.option, .shift]))
    static let togglePause = Self("togglePause", initial: .init(.p, modifiers: [.option, .shift]))
    static let togglePanel = Self("togglePanel", initial: .init(.t, modifiers: [.option, .shift]))
}

/// Global hotkeys: ⌥⇧R start/stop, ⌥⇧P pause/resume, ⌥⇧T show/hide the panel (rebindable in Settings).
/// They go through the same controller commands as the panel buttons.
@MainActor
enum HotkeyCenter {
    static func install(controller: RecordingController, statusItem: StatusItemController) {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            Task {
                if controller.isRecording { await controller.stop() } else { await controller.start() }
            }
        }
        KeyboardShortcuts.onKeyUp(for: .togglePause) {
            Task { await controller.togglePause() }
        }
        KeyboardShortcuts.onKeyUp(for: .togglePanel) {
            statusItem.togglePanel()
        }
    }
}
