import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Only registered while the countdown is showing, so Esc keeps working everywhere else.
    static let cancelCountdown = Self("cancelCountdown", initial: .init(.escape))
}

/// The 3-2-1 before recording, centred on the capture target. Clicking it (or ⌥⇧R) skips it; Esc cancels.
@MainActor
final class Countdown {
    private enum Outcome { case running, skipped, cancelled }

    private var panel: OverlayPanel?
    private var outcome = Outcome.running
    private let model = CountdownModel()

    var isRunning: Bool { panel != nil }

    init() {
        KeyboardShortcuts.disable(.cancelCountdown)
        KeyboardShortcuts.onKeyUp(for: .cancelCountdown) { [weak self] in self?.cancel() }
    }

    /// Returns when the countdown ends or is skipped; throws `CancellationError` when cancelled.
    /// `target` is the capture area in global points.
    func run(over target: CGRect) async throws {
        outcome = .running
        let size = CGSize(width: 220, height: 220)
        let center = ScreenSpace.flip(CGPoint(x: target.midX, y: target.midY))
        let panel = OverlayPanel(
            frame: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
            activating: false)
        panel.contentView = NSHostingView(rootView: CountdownView(model: model) { [weak self] in self?.skip() })
        panel.orderFrontRegardless()
        self.panel = panel
        KeyboardShortcuts.enable(.cancelCountdown)
        defer {
            KeyboardShortcuts.disable(.cancelCountdown)
            panel.orderOut(nil)
            self.panel = nil
        }
        for tenth in 0..<30 {
            model.number = 3 - tenth / 10
            try? await Task.sleep(for: .milliseconds(100))
            switch outcome {
            case .running: continue
            case .skipped: return
            case .cancelled: throw CancellationError()
            }
        }
    }

    func skip() { if isRunning { outcome = .skipped } }
    func cancel() { if isRunning { outcome = .cancelled } }
}

@MainActor @Observable
private final class CountdownModel {
    var number = 3
}

private struct CountdownView: View {
    let model: CountdownModel
    let skip: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text("\(model.number)")
                .font(.system(size: 96, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: model.number)
            Text("Click to skip · Esc to cancel")
                .font(.caption)
        }
        .foregroundStyle(.white)
        .frame(width: 200, height: 200)
        .background(.black.opacity(0.6), in: Circle())
        .contentShape(Circle())
        .onTapGesture(perform: skip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording starts in \(model.number)")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
