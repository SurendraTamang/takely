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
    private let fallbackAnchor: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }()

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
        if Self.isBehindNotch(button) {
            showFromFallbackAnchor()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if !popover.isShown { showFromFallbackAnchor() }
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePanel() {
        popover.performClose(nil)
    }

    /// An NSPopover keeps its SwiftUI view alive, so refresh here rather than in the view's `.task`.
    func popoverWillShow(_ notification: Notification) {
        Task { await model.refreshDisplays() }
    }

    func popoverDidClose(_ notification: Notification) {
        fallbackAnchor.orderOut(nil)
    }

    /// When the icon can't anchor the panel (hidden behind the notch), anchor it to an invisible point at the top right.
    private func showFromFallbackAnchor() {
        guard let screen = NSScreen.main, let view = fallbackAnchor.contentView else { return }
        let frame = screen.visibleFrame
        fallbackAnchor.setFrameOrigin(NSPoint(x: frame.maxX - 180, y: frame.maxY - 1))
        fallbackAnchor.orderFrontRegardless()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// True when the icon sits in the gap the camera housing covers (between the screen's auxiliary top areas).
    private static func isBehindNotch(_ button: NSStatusBarButton) -> Bool {
        guard let window = button.window, let screen = window.screen ?? NSScreen.main,
            let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return false }
        return window.frame.midX > left.maxX && window.frame.midX < right.minX
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
            button.attributedTitle = NSAttributedString(
                string: " " + elapsed.formatted(.time(pattern: .minuteSecond)),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)])
            button.imagePosition = .imageLeading
        case .exporting:
            button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Exporting")
            button.attributedTitle = NSAttributedString()
        case .idle, .starting:
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Takely")
            button.attributedTitle = NSAttributedString()
        }
    }
}
