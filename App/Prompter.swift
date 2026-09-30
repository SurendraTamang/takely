import AppCore
import AppKit
import SwiftUI

/// The invisible prompter: a floating script panel that recordings never show (Takely's windows are excluded from
/// capture). It can scroll by itself at a reading speed, and follow the recording (scroll while recording).
@MainActor
final class Prompter {
    let model: PrompterModel
    private var panel: NSPanel?

    init(settings: RecordingSettings) {
        model = PrompterModel(settings: settings)
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        model.scrolling = false
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 560, height: 240)
        let panel = NSPanel(
            contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 8, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "Prompter"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false  // clicking the text makes it key, so Space and the arrows work
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("TakelyPrompter")  // AppKit remembers where the user put it
        panel.contentView = NSHostingView(rootView: PrompterView(model: model))
        return panel
    }
}

/// Prompter state over the saved settings.
@MainActor @Observable
final class PrompterModel {
    let settings: RecordingSettings
    var scrolling = false
    var editing = false

    init(settings: RecordingSettings) {
        self.settings = settings
        editing = settings.prompterScript.isEmpty
    }

}

private struct PrompterView: View {
    @Bindable var model: PrompterModel
    @State private var position = ScrollPosition(edge: .top)
    /// Where the scroll is (kept exactly; the scroll view reports rounded offsets, which would stall slow speeds).
    @State private var offset = 0.0
    @State private var maxOffset = 0.0
    @State private var lastTick: Date?
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            toolbar
            if model.editing {
                TextEditor(text: $settings.prompterScript)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                ScrollView {
                    Text(settings.prompterScript.isEmpty ? "Click Edit to add your script." : settings.prompterScript)
                        .font(.system(size: settings.prompterFontSize, weight: .medium))
                        .lineSpacing(settings.prompterFontSize * 0.3)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 60)
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: [Double].self) { geometry in
                    [geometry.contentOffset.y, geometry.contentSize.height - geometry.containerSize.height]
                } action: { _, values in
                    if !model.scrolling || abs(values[0] - offset) > 2 { offset = values[0] }  // the user scrolled
                    maxOffset = values[1]
                }
                .scaleEffect(x: settings.prompterMirrored ? -1 : 1, y: 1)
                .background {
                    // Drives scrolling only while it runs (no timer when paused or hidden).
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !model.scrolling)) { timeline in
                        Color.clear.onChange(of: timeline.date) { _, now in step(to: now) }
                    }
                }
                .onChange(of: model.scrolling) { lastTick = nil }
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onTapGesture { focused = true }
                .onKeyPress(.space) {
                    model.scrolling.toggle()
                    return .handled
                }
                .onKeyPress(.upArrow) { nudge(-settings.prompterFontSize * 2) }
                .onKeyPress(.downArrow) { nudge(settings.prompterFontSize * 2) }
            }
        }
        .background(.black.opacity(settings.prompterOpacity))
        .frame(minWidth: 320, minHeight: 140)
    }

    private func nudge(_ distance: Double) -> KeyPress.Result {
        offset = min(max(0, offset + distance), max(0, maxOffset))
        position.scrollTo(y: offset)
        return .handled
    }

    /// Advances by the time since the last frame, at the pace that reads the script in its spoken time.
    private func step(to now: Date) {
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let words = model.settings.prompterScript.split(whereSeparator: \.isWhitespace).count
        let speed = PrompterScroll.pointsPerSecond(
            scrollableHeight: maxOffset, wordCount: words, wordsPerMinute: model.settings.prompterWordsPerMinute)
        offset = PrompterScroll.advance(offset, by: now.timeIntervalSince(last), speed: speed, maxOffset: maxOffset)
        position.scrollTo(y: offset)
    }

    private var toolbar: some View {
        @Bindable var settings = model.settings
        return HStack(spacing: 10) {
            Button {
                model.scrolling.toggle()
            } label: {
                Image(systemName: model.scrolling ? "pause.fill" : "play.fill")
            }
            .help(model.scrolling ? "Pause scrolling (Space)" : "Scroll (Space)")
            .disabled(model.editing)
            Button(model.editing ? "Done" : "Edit") {
                model.editing.toggle()
                model.scrolling = false
            }
            Spacer()
            Label("\(Int(settings.prompterWordsPerMinute)) wpm", systemImage: "speedometer").labelStyle(.titleOnly).font(.caption)
            Slider(value: $settings.prompterWordsPerMinute, in: 80...220, step: 10).frame(width: 80).help("Reading speed")
            Stepper("Size", value: $settings.prompterFontSize, in: 18...72, step: 2).labelsHidden().help("Text size")
            Slider(value: $settings.prompterOpacity, in: 0.3...1).frame(width: 60).help("Background opacity")
            Toggle(isOn: $settings.prompterMirrored) { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .toggleStyle(.button)
                .help("Mirror (for a beam-splitter prompter)")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.top, 28)  // clear of the transparent title bar's close button
        .padding(.bottom, 6)
    }
}
