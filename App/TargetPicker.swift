import AppKit
import CaptureKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Conversions between AppKit screen coordinates (origin bottom-left of the primary display) and global
/// coordinates (origin top-left; CoreGraphics and ScreenCaptureKit). The flip is its own inverse.
enum ScreenSpace {
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryHeight - point.y) }
}

/// A borderless panel above everything, on all Spaces. Takely's windows never appear in recordings: the stream
/// filter excludes the app.
final class OverlayPanel: NSPanel {
    /// Pickers take keys (Esc, Return); the drawing canvas and palette mustn't swallow the user's typing.
    var takesKeys = true
    init(frame: CGRect, activating: Bool, level: NSWindow.Level = .screenSaver) {
        super.init(
            contentRect: frame, styleMask: activating ? [.borderless] : [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { takesKeys }
}

/// A window the user can record: its frame is in global points.
/// `@unchecked Sendable`: `SCWindow` is an immutable snapshot.
struct PickableWindow: Identifiable, @unchecked Sendable {
    let window: SCWindow
    var id: CGWindowID { window.windowID }
    var frame: CGRect { window.frame }
    var title: String {
        let app = window.owningApplication?.applicationName ?? ""
        let title = window.title ?? ""
        return title.isEmpty || title == app ? app : "\(app) — \(title)"
    }
}

/// Full-screen pickers for a region or a window: one overlay per display, Esc cancels.
@MainActor
final class TargetPicker {
    private var panels: [OverlayPanel] = []
    private var keys: Any?
    /// Completes the picker that's showing (nil = cancelled); a new picker or `close` always completes the old one.
    private var cancelPending: (() -> Void)?

    /// The dragged region in global points, clamped to the display it started on; nil if cancelled.
    /// Return confirms `initial` (the last region) without dragging.
    func pickRegion(initial: CGRect?) async -> CGRect? {
        await present { screen, scale, finish in
            AnyView(RegionSelectionView(screen: screen, scale: scale, initial: initial, finish: finish))
        } confirm: {
            // Only if it's still on a connected display.
            initial.flatMap { region in
                NSScreen.screens.lazy.compactMap { CaptureGeometry.clamp(region, to: ScreenSpace.flip($0.frame)) }.first
            }
        }
    }

    /// The window clicked, from the on-screen windows of other apps; nil if cancelled or none can be listed.
    func pickWindow() async -> SCWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let own = Bundle.main.bundleIdentifier
        // Front-to-back order, so the topmost window under the pointer wins.
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let windows = content.windows
            .filter {
                $0.windowLayer == 0 && $0.isOnScreen && $0.owningApplication?.bundleIdentifier != own
                    && $0.frame.width >= CaptureGeometry.minimumSize && $0.frame.height >= CaptureGeometry.minimumSize
            }
            .sorted { rank[$0.windowID, default: .max] < rank[$1.windowID, default: .max] }
            .map(PickableWindow.init)
        let picked: PickableWindow? = await present { screen, _, finish in
            AnyView(WindowSelectionView(screen: screen, windows: windows, finish: finish))
        } confirm: {
            nil
        }
        return picked?.window
    }

    /// Shows `content` on every display and waits for one of them to finish (nil = cancelled).
    private func present<T: Sendable>(
        _ content: (_ screen: CGRect, _ scale: CGFloat, _ finish: @escaping (T?) -> Void) -> AnyView, confirm: @escaping () -> T?
    ) async -> T? {
        close()
        return await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (T?) -> Void = { [weak self] value in
                guard !resumed else { return }
                resumed = true
                self?.cancelPending = nil
                self?.close()
                continuation.resume(returning: value)
            }
            cancelPending = { finish(nil) }
            for screen in NSScreen.screens {
                let panel = OverlayPanel(frame: screen.frame, activating: true)
                panel.contentView = NSHostingView(rootView: content(ScreenSpace.flip(screen.frame), screen.backingScaleFactor, finish))
                panels.append(panel)
                panel.orderFrontRegardless()
            }
            // Esc cancels, Return confirms, whichever overlay has focus.
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 53: finish(nil)
                case 36, 76: if let value = confirm() { finish(value) }
                default: return event
                }
                return nil
            }
            NSApp.activate()
            let underPointer = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first
            underPointer?.makeKey()
            if panels.isEmpty { finish(nil) }
        }
    }

    private func close() {
        cancelPending?()
        keys.map(NSEvent.removeMonitor)
        keys = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }
}

/// Dims one display; dragging cuts out the region, with its size in pixels.
private struct RegionSelectionView: View {
    /// This display's frame in global points.
    let screen: CGRect
    let scale: CGFloat
    let initial: CGRect?
    let finish: (CGRect?) -> Void
    @State private var dragged: CGRect?

    var body: some View {
        let shown = dragged ?? initial.flatMap { screen.intersects($0) ? $0 : nil }
        let local = shown.map { $0.offsetBy(dx: -screen.minX, dy: -screen.minY) }
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: screen.size))
                if let local { path.addRect(local) }
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            if let local, let shown {
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1)
                    .frame(width: local.width, height: local.height)
                    .offset(x: local.minX, y: local.minY)
                let pixels = CaptureGeometry.pixelSize(of: shown, scale: scale)
                Text(dragged == nil ? "Return to record this area again, or drag a new one" : "\(pixels.width) × \(pixels.height)")
                    .font(.callout.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white)
                    .offset(x: local.minX, y: max(0, local.minY - 30))
            } else {
                Text("Drag to select the area to record · Esc to cancel")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: screen.width, height: screen.height)
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    dragged =
                        CGRect(
                            x: value.startLocation.x + screen.minX, y: value.startLocation.y + screen.minY,
                            width: value.location.x - value.startLocation.x, height: value.location.y - value.startLocation.y
                        ).standardized
                }
                .onEnded { _ in
                    // Too small (e.g. a click): stay open for another try.
                    if let dragged, let region = CaptureGeometry.clamp(dragged, to: screen) { finish(region) } else { dragged = nil }
                }
        )
        .pointerStyle(.rectSelection)
    }
}

/// Highlights the window under the pointer on one display; a click picks it.
private struct WindowSelectionView: View {
    let screen: CGRect
    let windows: [PickableWindow]
    let finish: (PickableWindow?) -> Void
    @State private var hovered: PickableWindow?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.2)
            if let hovered {
                let local = hovered.frame.offsetBy(dx: -screen.minX, dy: -screen.minY)
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.25))
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: local.width, height: local.height)
                    .offset(x: local.minX, y: local.minY)
                Text("\(hovered.title)  \(Int(hovered.frame.width)) × \(Int(hovered.frame.height))")
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white)
                    .offset(x: local.minX + 8, y: local.minY + 8)
            } else {
                Text("Click a window to record it · Esc to cancel")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: screen.width, height: screen.height)
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case .active(let point) = phase else { return hovered = nil }
            let global = CGPoint(x: point.x + screen.minX, y: point.y + screen.minY)
            hovered = windows.first { $0.frame.contains(global) }
        }
        .onTapGesture { if let hovered { finish(hovered) } }
    }
}
