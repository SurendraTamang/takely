import AppCore
import AppKit
import SwiftUI

#if canImport(TakelyPro)
    import TakelyPro
#endif

/// The invisible prompter: a floating script panel that recordings never show (Takely's windows are excluded from
/// capture). It can scroll by itself at a reading speed, and follow the recording (scroll while recording).
@MainActor
final class Prompter {
    let model: PrompterModel
    private var panel: NSPanel?

    init(settings: RecordingSettings, live: LiveStatus, practice: @escaping (Bool) -> Void) {
        model = PrompterModel(settings: settings, live: live, practice: practice)
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
    /// The voice-following position (Takely Pro), when it's following.
    let live: LiveStatus
    /// Starts (true) or stops (false) a practice run of voice-following without recording.
    let practice: (Bool) -> Void
    var scrolling = false
    var editing = false
    var practicing = false
    /// A retake took back this many seconds: the time-paced scroll goes back as far (`id` changes per request).
    private(set) var rewind: (id: Int, seconds: Double)?

    func rewind(by seconds: Double) {
        guard seconds > 0 else { return }
        rewind = ((rewind?.id ?? 0) + 1, seconds)
    }

    init(settings: RecordingSettings, live: LiveStatus, practice: @escaping (Bool) -> Void) {
        self.settings = settings
        self.live = live
        self.practice = practice
        editing = settings.prompterScript.isEmpty
    }

    #if canImport(TakelyPro)
        var isWriting: Bool { writing != nil }
        func stopWriting() { writing?.cancel() }
    #else
        var isWriting: Bool { false }
        func stopWriting() {}
    #endif

    #if canImport(TakelyPro)
        /// Writing a script from notes: the notes (kept, to write again from them) and the script made from them.
        private var notes: String?
        private var written: String?
        var writing: Task<Void, Never>?
        var writeNote: String?

        /// Replaces the editor's text with a spoken script written from it (or, if the editor still holds the last
        /// script written, from that script's notes), streamed in as the model writes.
        func writeScript(tone: ScriptWriter.Tone, minutes: Int) {
            guard ScriptWriter.isAvailable else {
                writeNote = "Writing a script needs Apple Intelligence: turn it on in System Settings › Apple Intelligence & Siri."
                return
            }
            let source = settings.prompterScript == written ? notes ?? settings.prompterScript : settings.prompterScript
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                writeNote = "Type your notes first: the points to cover, in any order."
                return
            }
            notes = source
            writeNote = nil
            writing?.cancel()
            let before = settings.prompterScript
            writing = Task {
                do {
                    for try await script in ScriptWriter.write(notes: source, tone: tone, minutes: minutes) {
                        settings.prompterScript = script
                    }
                    try Task.checkCancellation()  // a cancelled stream may just end
                    written = settings.prompterScript
                } catch is CancellationError {
                    settings.prompterScript = before
                } catch {
                    writeNote = "Couldn't write the script: \(error.localizedDescription)"
                    settings.prompterScript = before
                }
                writing = nil
            }
        }
    #endif
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
            #if canImport(TakelyPro)
                if let note = model.writeNote, model.editing {
                    Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                }
            #endif
            if let note = model.live.note {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            if let spoken = model.live.spokenCharacters, !model.editing {
                FollowingScript(script: settings.prompterScript, spokenCharacters: spoken, fontSize: settings.prompterFontSize)
                    .scaleEffect(x: settings.prompterMirrored ? -1 : 1, y: 1)
            } else if model.editing {
                TextEditor(text: $settings.prompterScript)
                    .disabled(model.isWriting)  // the streamed script would overwrite typing
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
                .onChange(of: model.rewind?.id) {
                    // Only while it scrolls by itself (not paused, hidden, or moved by hand).
                    guard model.scrolling, let seconds = model.rewind?.seconds else { return }
                    offset = max(0, offset - speed * seconds)
                    position.scrollTo(y: offset)
                }
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

    /// Points per second that read the script in its spoken time.
    private var speed: Double {
        let words = model.settings.prompterScript.split(whereSeparator: \.isWhitespace).count
        return PrompterScroll.pointsPerSecond(
            scrollableHeight: maxOffset, wordCount: words, wordsPerMinute: model.settings.prompterWordsPerMinute)
    }

    /// Advances by the time since the last frame, at the pace that reads the script in its spoken time.
    private func step(to now: Date) {
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let speed = speed
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
                model.stopWriting()
                model.editing.toggle()
                model.scrolling = false
            }
            #if canImport(TakelyPro)
                Button(model.practicing ? "Stop Practice" : "Practice") {
                    model.practicing.toggle()
                    model.practice(model.practicing)
                }
                .help("Read the script aloud: the prompter follows your voice, without recording")
                .disabled(model.editing || settings.prompterScript.isEmpty || model.live.recording)
                if model.editing {
                    Menu(model.writing == nil ? "Write Script" : "Writing…") {
                        ForEach(ScriptWriter.Tone.allCases, id: \.self) { tone in
                            Section(tone.rawValue.capitalized) {
                                ForEach([1, 2, 3], id: \.self) { minutes in
                                    Button("About \(minutes) min") { model.writeScript(tone: tone, minutes: minutes) }
                                }
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(model.writing != nil)
                    .help("Turn your notes into a script to read aloud (on-device Apple Intelligence)")
                }
            #endif
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

/// The script with spoken words dimmed, scrolled so the next words sit a third of the way down (voice-following).
/// AppKit text view: SwiftUI's `Text` can't tell where a character is laid out.
struct FollowingScript: NSViewRepresentable {
    let script: String
    let spokenCharacters: Int
    let fontSize: Double

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = false
            text.drawsBackground = false
            text.textContainerInset = NSSize(width: 16, height: 40)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, let layout = text.layoutManager, let container = text.textContainer
        else { return }
        let spoken = min(spokenCharacters, script.count)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.3
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attributed = NSMutableAttributedString(
            string: script, attributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: style])
        let spokenRange = NSRange(script.startIndex..<script.index(script.startIndex, offsetBy: spoken), in: script)
        attributed.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.35), range: spokenRange)
        text.textStorage?.setAttributedString(attributed)
        // Scroll the line holding the next word to a third of the way down.
        layout.ensureLayout(for: container)
        let next = NSRange(location: min(spokenRange.upperBound, max(0, attributed.length - 1)), length: attributed.length > 0 ? 1 : 0)
        let glyphs = layout.glyphRange(forCharacterRange: next, actualCharacterRange: nil)
        let line = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let maxOffset = max(0, text.frame.height - scroll.contentView.bounds.height)
        let target = min(maxOffset, max(0, line.minY + text.textContainerInset.height - scroll.contentView.bounds.height / 3))
        guard abs(scroll.contentView.bounds.origin.y - target) > 1 else { return }
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0.35
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
