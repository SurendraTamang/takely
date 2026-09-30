@preconcurrency import AVFoundation
import AppKit
import ProjectKit

/// The camera session shared by the bubble's live preview and the recording, so the camera is already warm when
/// recording starts. It stops 30 s after nothing needs it.
@MainActor
final class CameraController {
    nonisolated let session = AVCaptureSession()
    nonisolated let queue = DispatchQueue(label: "app.takely.camera-session")
    private var deviceID: String??
    private var idleStop: Task<Void, Never>?

    /// Starts the camera (switching to `deviceID`, or the default camera for nil) if permission is granted.
    func start(deviceID: String?) {
        idleStop?.cancel()
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        let changed = self.deviceID != .some(deviceID)
        self.deviceID = deviceID
        let session = session
        queue.async {
            if changed {
                session.beginConfiguration()
                session.inputs.forEach(session.removeInput)
                let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? .default(for: .video)
                if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                session.commitConfiguration()
            }
            if !session.isRunning, !session.inputs.isEmpty { session.startRunning() }
        }
    }

    /// Stops the camera after 30 s unless something starts it again.
    func stopSoon() {
        idleStop?.cancel()
        let session = session
        let queue = queue
        idleStop = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            queue.async { session.stopRunning() }
        }
    }
}

/// The floating camera bubble: a live preview the user drags (moving the window), resizes with the scroll wheel,
/// and styles from its context menu. It isn't captured; its moves are recorded as keyframes and composited at export.
@MainActor
final class BubblePanel: NSPanel, NSWindowDelegate {
    /// Called after a move, resize or style change with the bubble's frame (AppKit screen coordinates).
    var onChange: () -> Void = {}
    var onHide: () -> Void = {}
    private let preview: PreviewView
    private(set) var shape: BubbleShape

    static let sizes: [(name: String, diameter: Double)] = [("Small", 120), ("Medium", 180), ("Large", 260)]

    init(session: AVCaptureSession, diameter: Double, shape: BubbleShape, origin: CGPoint?) {
        preview = PreviewView(session: session)
        self.shape = shape
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let start = origin ?? CGPoint(x: screen.maxX - diameter - 40, y: screen.minY + 40)
        super.init(
            contentRect: CGRect(origin: start, size: CGSize(width: diameter, height: diameter)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        delegate = self
        contentView = preview
        preview.scroll = { [weak self] delta in self?.resize(by: delta) }
        preview.menu = makeMenu()
        applyShape()
        setAccessibilityLabel("Camera bubble")
    }

    var diameter: Double { frame.width }

    func windowDidMove(_ notification: Notification) { onChange() }

    func setShape(_ shape: BubbleShape) {
        self.shape = shape
        applyShape()
        onChange()
    }

    func setDiameter(_ diameter: Double) {
        let d = min(max(diameter, 100), 400)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        setFrame(CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d), display: true)
        applyShape()
        onChange()
    }

    private func resize(by delta: CGFloat) { setDiameter(diameter + delta * 2) }

    private func applyShape() {
        let d = diameter
        preview.layer?.cornerRadius =
            switch shape {
            case .circle: d / 2
            case .rounded: d * 0.22
            case .square: 0
            }
        invalidateShadow()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, shape) in [("Circle", BubbleShape.circle), ("Rounded", .rounded), ("Square", .square)] {
            menu.addItem(ActionItem(title) { [weak self] in self?.setShape(shape) })
        }
        menu.addItem(.separator())
        for size in Self.sizes {
            menu.addItem(ActionItem(size.name) { [weak self] in self?.setDiameter(size.diameter) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Hide Camera") { [weak self] in self?.onHide() })
        return menu
    }
}

/// The camera preview, filled to the bubble and clipped to its shape.
private final class PreviewView: NSView {
    var scroll: (CGFloat) -> Void = { _ in }

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.masksToBounds = true
        self.layer = layer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func scrollWheel(with event: NSEvent) { scroll(event.scrollingDeltaY) }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func runAction() { run() }
}
