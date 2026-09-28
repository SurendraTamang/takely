import AppCore
import AppKit
import SwiftUI

/// The menu bar icon and its panel. Replaces SwiftUI's `MenuBarExtra`, which can't open its panel from
/// code, so the ⌥⇧T hotkey can show it even when the icon is hidden behind the notch.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: RecorderModel

    init(model: RecorderModel) {
        self.model = model
        super.init()
        let host = NSHostingController(rootView: RecorderMenu(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.setAccessibilityLabel("Takely")
        render()
    }

    @objc func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let button = item.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePanel() {
        popover.performClose(nil)
    }

    /// An NSPopover keeps its SwiftUI view alive, so refresh here rather than in the view's `.task`.
    func popoverWillShow(_ notification: Notification) {
        Task { await model.refreshDisplays() }
    }

    /// Redraws the icon now and again whenever the controller's phase or elapsed time changes.
    private func render() {
        let controller = model.controller
        withObservationTracking {
            apply(phase: controller.phase, elapsed: controller.elapsed)
        } onChange: {
            Task { @MainActor [weak self] in self?.render() }
        }
    }

    private func apply(phase: RecordingController.Phase, elapsed: Duration) {
        guard let button = item.button else { return }
        switch phase {
        case .recording, .paused, .stopping:
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = NSImage(
                systemSymbolName: phase == .paused ? "pause.circle.fill" : "record.circle.fill", accessibilityDescription: "Recording")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
            button.image = image
            button.title = " " + elapsed.formatted(.time(pattern: .minuteSecond))
            button.imagePosition = .imageLeading
        case .exporting:
            button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Exporting")
            button.title = ""
        case .idle, .starting:
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Takely")
            button.title = ""
        }
    }
}
