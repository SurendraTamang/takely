import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Only registered while drawing, so Esc keeps working everywhere else.
    static let exitDrawing = Self("exitDrawing", initial: .init(.escape))
}

/// On-screen drawing that **is** recorded: a transparent panel over the recorded display that the stream filter
/// lets through (`exceptingWindows`). It stays click-through until draw mode is on; strokes fade after 3 s.
/// The colour palette is a separate panel, so it isn't recorded.
@MainActor
final class DrawingOverlay {
    private let model = DrawingModel()
    private var canvas: OverlayPanel?
    private var palette: OverlayPanel?

    var isDrawing: Bool { model.drawing }

    init() {
        KeyboardShortcuts.disable(.exitDrawing)
        KeyboardShortcuts.onKeyUp(for: .exitDrawing) { [weak self] in self?.setDrawing(false) }
    }

    /// Puts the (empty, click-through) canvas over `display` (global points) and returns its window number, for the
    /// stream filter to include. Called before each display or area recording.
    func prepare(on display: CGRect) -> CGWindowID {
        teardown()
        let panel = OverlayPanel(frame: ScreenSpace.flip(display), activating: false, level: .screenSaver)
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: DrawingCanvas(model: model))
        panel.orderFrontRegardless()
        canvas = panel
        return CGWindowID(panel.windowNumber)
    }

    /// ⌥⇧D: draw mode on or off (only while a canvas is up, i.e. during a display or area recording).
    func toggle() { setDrawing(!model.drawing) }

    func teardown() {
        setDrawing(false)
        canvas?.orderOut(nil)
        canvas = nil
        model.strokes = []
    }

    private func setDrawing(_ on: Bool) {
        guard let canvas else { return model.drawing = false }
        model.drawing = on
        canvas.ignoresMouseEvents = !on
        if on {
            KeyboardShortcuts.enable(.exitDrawing)
            showPalette(over: canvas.frame)
        } else {
            KeyboardShortcuts.disable(.exitDrawing)
            palette?.orderOut(nil)
            palette = nil
        }
    }

    private func showPalette(over frame: CGRect) {
        let host = NSHostingView(rootView: DrawingPalette(model: model) { [weak self] in self?.setDrawing(false) })
        let size = host.fittingSize
        let panel = OverlayPanel(
            frame: CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 40, width: size.width, height: size.height),
            activating: false, level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1))
        panel.contentView = host
        panel.orderFrontRegardless()
        palette = panel
    }
}

@MainActor @Observable
private final class DrawingModel {
    struct Stroke {
        var points: [CGPoint]
        var color: Color
        var ended: Date?
    }

    static let colors: [Color] = [.red, .yellow, .green, .blue, .white]
    var drawing = false
    var color = colors[0]
    var strokes: [Stroke] = []
}

/// Strokes stay 2 s, then fade out over 1 s.
private struct DrawingCanvas: View {
    let model: DrawingModel

    var body: some View {
        TimelineView(.animation(paused: model.strokes.isEmpty)) { timeline in
            Canvas { context, _ in
                for stroke in model.strokes {
                    let age = stroke.ended.map { timeline.date.timeIntervalSince($0) } ?? 0
                    let opacity = min(1, max(0, 3 - age))
                    guard opacity > 0, stroke.points.count > 1 else { continue }
                    var path = Path()
                    path.addLines(stroke.points)
                    context.stroke(
                        path, with: .color(stroke.color.opacity(opacity)),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            .onChange(of: timeline.date) { _, now in
                model.strokes.removeAll { $0.ended.map { now.timeIntervalSince($0) > 3 } ?? false }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if model.strokes.last.map({ $0.ended != nil }) ?? true {
                        model.strokes.append(.init(points: [value.startLocation], color: model.color))
                    }
                    model.strokes[model.strokes.count - 1].points.append(value.location)
                }
                .onEnded { _ in
                    if !model.strokes.isEmpty { model.strokes[model.strokes.count - 1].ended = .now }
                }
        )
        .pointerStyle(model.drawing ? .rectSelection : .default)
    }
}

private struct DrawingPalette: View {
    @Bindable var model: DrawingModel
    let done: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(DrawingModel.colors.enumerated()), id: \.offset) { _, color in
                Circle()
                    .fill(color)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(.white, lineWidth: model.color == color ? 3 : 0))
                    .onTapGesture { model.color = color }
            }
            Button("Done", action: done).controlSize(.small)
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
    }
}
