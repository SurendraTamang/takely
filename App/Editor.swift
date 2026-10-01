#if canImport(TakelyPro)
    import AVKit
    import ProjectKit
    import RenderKit
    import SwiftUI
    import TakelyPro

    /// The editor (Takely Pro): a preview of the edited recording, a timeline of the whole recording with its cuts
    /// (greyed, click to restore), trim handles and zooms, the transcript to cut by word, and the automatic tools.
    @MainActor @Observable
    final class EditorModel {
        let session: EditSession
        let player = AVPlayer()
        var thumbnails: [CGImage?] = []
        /// A range picked on the timeline (recording time), to cut.
        var selection: TimeRange?
        var selectedWords: Set<Int> = []
        var selectedZoom: Zoom.ID?
        /// Where the preview is, in recording time.
        var playhead = 0.0
        var error: String?
        private let frames: RecordingFrames
        private var shownEdits: Edits?
        private var refresh: Task<Void, Never>?
        @ObservationIgnored private var observer: Any?

        init(session: EditSession) throws {
            self.session = session
            frames = RecordingFrames(bundle: session.bundle, segments: try session.bundle.readProject().segments)
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, self.player.rate != 0 else { return }
                    self.playhead = self.session.map.sourceTime(time.seconds)
                }
            }
        }

        func loadThumbnails(count: Int = 14) async {
            guard thumbnails.isEmpty else { return }
            thumbnails = Array(repeating: nil, count: count)
            for i in 0..<count {
                thumbnails[i] = await frames.frame(
                    at: (Double(i) + 0.5) * session.duration / Double(count), size: CGSize(width: 240, height: 135))
            }
        }

        /// Rebuilds the preview when the edits changed (briefly debounced, so a drag doesn't rebuild every step).
        func updatePreview() {
            guard shownEdits != session.edits else { return }
            refresh?.cancel()
            refresh = Task {
                try? await Task.sleep(for: .milliseconds(shownEdits == nil ? 0 : 150))
                guard !Task.isCancelled else { return }
                let edits = session.edits
                do {
                    let built = try await Exporter.compose(session.bundle, edits: edits)
                    guard !Task.isCancelled else { return }
                    let wasPlaying = player.rate != 0
                    player.replaceCurrentItem(with: built.playerItem())
                    shownEdits = edits
                    error = nil
                    seek(to: playhead)
                    if wasPlaying { player.play() }
                } catch {
                    self.error = "Can't preview: \(error.localizedDescription)"
                }
            }
        }

        func seek(to t: Double) {
            playhead = min(max(0, t), session.duration)
            let output = CMTime(seconds: session.map.position(playhead), preferredTimescale: 600)
            player.seek(to: output, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        /// Cuts the selected range or words.
        func cutSelection() {
            if let selection {
                session.cut(selection)
                self.selection = nil
            } else if !selectedWords.isEmpty {
                session.cut(words: Array(selectedWords))
                selectedWords = []
            }
        }

        var canCut: Bool { selection != nil || !selectedWords.isEmpty }
    }

    struct EditorView: View {
        @Bindable var model: EditorModel
        /// Saves and starts the export; returns why it can't, if it can't.
        let export: () -> String?
        @State private var proposal: (title: String, proposal: EditSession.Proposal)?

        private var session: EditSession { model.session }

        var body: some View {
            VStack(spacing: 0) {
                HSplitView {
                    VideoPlayer(player: model.player)
                        .frame(minWidth: 480, minHeight: 270)
                    TranscriptPane(model: model)
                        .frame(minWidth: 220, idealWidth: 280)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    toolbar
                    Timeline(model: model)
                        .frame(height: 96)
                    if let id = model.selectedZoom, let zoom = session.edits.zooms.first(where: { $0.id == id }) {
                        ZoomInspector(model: model, zoom: zoom)
                    }
                    if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                .padding(12)
            }
            .frame(minWidth: 820, minHeight: 560)
            .task {
                model.updatePreview()
                await model.loadThumbnails()
            }
            .onChange(of: session.edits) { model.updatePreview() }
            .confirmationDialog(
                proposal?.title ?? "", isPresented: Binding(get: { proposal != nil }, set: { if !$0 { proposal = nil } }),
                presenting: proposal
            ) { item in
                Button("Cut \(item.proposal.count) place\(item.proposal.count == 1 ? "" : "s")") { session.apply(item.proposal) }
            } message: { item in
                Text("Saves \(Self.time(item.proposal.saved)). You can restore any cut on the timeline, or undo.")
            }
        }

        private var toolbar: some View {
            HStack(spacing: 8) {
                Button("Undo", systemImage: "arrow.uturn.backward") { session.undo() }
                    .keyboardShortcut("z").disabled(!session.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward") { session.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo)
                Divider().frame(height: 18)
                Button("Cut", systemImage: "scissors") { model.cutSelection() }
                    .keyboardShortcut(.delete, modifiers: []).disabled(!model.canCut)
                    .help("Cut the selected range or words (⌫)")
                Button("Add Zoom", systemImage: "plus.magnifyingglass") { session.addZoom(at: model.playhead) }
                    .help("Zoom in for 3 seconds at the playhead, following the cursor")
                Menu("Tools") {
                    Button("Remove Silences…") { propose("Remove long pauses?", session.proposeSilenceCuts()) }
                    Button("Remove Filler Words…") { propose("Remove filler words?", session.proposeFillerCuts()) }
                    Button("Auto-Zoom on Clicks") {
                        let count = session.autoZoom()
                        model.error = count == 0 ? "No bursts of clicks to zoom into." : nil
                    }
                }
                .fixedSize()
                .help(session.transcript == nil ? "Removing silences and filler words needs a transcript (Settings › Takely Pro)." : "")
                Spacer()
                Text("\(Self.time(session.map.outputDuration)) of \(Self.time(session.duration))").monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Export") { model.error = export() }
                    .keyboardShortcut(.defaultAction)
            }
            .labelStyle(.iconOnly)
            .controlSize(.regular)
        }

        private func propose(_ title: String, _ proposal: EditSession.Proposal?) {
            guard let proposal else {
                model.error = "This needs a transcript: turn on “Transcribe recordings” in Settings, then record again."
                return
            }
            guard proposal.count > 0 else {
                model.error = "Nothing to remove."
                return
            }
            model.error = nil
            self.proposal = (title, proposal)
        }

        static func time(_ t: Double) -> String { Duration.seconds(t).formatted(.time(pattern: .minuteSecond)) }
    }

    /// The whole recording: thumbnails, cuts (click to restore), the selection, the trim handles, the zoom lane and
    /// the playhead. Click to seek, drag to select.
    private struct Timeline: View {
        @Bindable var model: EditorModel
        @State private var dragStart: Double?

        private var session: EditSession { model.session }

        var body: some View {
            GeometryReader { geometry in
                let width = geometry.size.width
                let x = { (t: Double) -> Double in t / max(session.duration, 0.001) * width }
                let t = { (x: Double) -> Double in min(max(0, x / max(width, 1) * session.duration), session.duration) }
                VStack(spacing: 4) {
                    ZStack(alignment: .topLeading) {
                        HStack(spacing: 0) {
                            ForEach(model.thumbnails.indices, id: \.self) { i in
                                ZStack {
                                    Rectangle().fill(.black)
                                    if let image = model.thumbnails[i] {
                                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                    }
                                }
                                .frame(width: width / Double(max(model.thumbnails.count, 1)), height: 60)
                                .clipped()
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let a = t(value.startLocation.x)
                                    let b = t(value.location.x)
                                    if abs(value.translation.width) < 3 {
                                        model.seek(to: b)
                                    } else {
                                        model.selection = TimeRange(start: min(a, b), end: max(a, b))
                                        model.selectedWords = []
                                    }
                                }
                                .onEnded { value in
                                    if abs(value.translation.width) < 3 { model.selection = nil }
                                })
                        ForEach(session.edits.cuts, id: \.self) { cut in
                            Rectangle().fill(.black.opacity(0.65))
                                .overlay(Image(systemName: "scissors").foregroundStyle(.white.opacity(0.7)))
                                .frame(width: max(2, x(cut.duration)), height: 60)
                                .offset(x: x(cut.start))
                                .onTapGesture { session.restore(cut) }
                                .help("Cut \(EditorView.time(cut.duration)) — click to restore")
                        }
                        if let selection = model.selection {
                            Rectangle().fill(.yellow.opacity(0.3)).border(.yellow, width: 1)
                                .frame(width: x(selection.duration), height: 60).offset(x: x(selection.start))
                                .allowsHitTesting(false)
                        }
                        trimHandle(at: session.trim.start, x: x, t: t, start: true)
                        trimHandle(at: session.trim.end, x: x, t: t, start: false)
                        Rectangle().fill(.red).frame(width: 2, height: 60).offset(x: x(model.playhead) - 1).allowsHitTesting(false)
                    }
                    .frame(height: 60)
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.quaternary).frame(height: 24)
                        ForEach(session.edits.zooms) { zoom in
                            ZoomBlock(model: model, zoom: zoom, x: x, t: t)
                        }
                    }
                    .frame(height: 24)
                }
            }
        }

        private func trimHandle(at time: Double, x: @escaping (Double) -> Double, t: @escaping (Double) -> Double, start: Bool) -> some View
        {
            RoundedRectangle(cornerRadius: 2).fill(.yellow)
                .frame(width: 8, height: 60)
                .offset(x: x(time) - (start ? 0 : 8))
                .gesture(
                    DragGesture()
                        .onEnded { value in
                            let moved = t(x(time) + value.translation.width)
                            if start {
                                session.setTrim(start: moved, end: session.trim.end)
                            } else {
                                session.setTrim(start: session.trim.start, end: moved)
                            }
                        }
                )
                .help(start ? "Drag to trim the start" : "Drag to trim the end")
        }
    }

    /// A zoom on the zoom lane: click to select, drag to move, drag its edges to resize.
    private struct ZoomBlock: View {
        @Bindable var model: EditorModel
        let zoom: Zoom
        let x: (Double) -> Double
        let t: (Double) -> Double
        @State private var draft: Zoom?

        var body: some View {
            let shown = draft ?? zoom
            let selected = model.selectedZoom == zoom.id
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? Color.accentColor : Color.accentColor.opacity(0.5))
                .overlay(Text("\(shown.scale, format: .number.precision(.fractionLength(1)))×").font(.caption2).foregroundStyle(.white))
                .overlay(alignment: .leading) { edge { d in shown.with(start: t(x(zoom.start) + d)) } }
                .overlay(alignment: .trailing) { edge { d in shown.with(end: t(x(zoom.end) + d)) } }
                .frame(width: max(6, x(shown.end) - x(shown.start)), height: 22)
                .offset(x: x(shown.start), y: 1)
                .onTapGesture { model.selectedZoom = selected ? nil : zoom.id }
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            let d = t(x(zoom.start) + value.translation.width) - zoom.start
                            draft = zoom.with(start: zoom.start + d).with(end: zoom.end + d)
                        }
                        .onEnded { _ in commit() })
        }

        /// A 6-point grip that resizes the zoom.
        private func edge(_ resize: @escaping (Double) -> Zoom) -> some View {
            Rectangle().fill(.white.opacity(0.6)).frame(width: 6)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in draft = resize(value.translation.width) }
                        .onEnded { _ in commit() })
        }

        private func commit() {
            if let draft { model.session.update(draft) }
            draft = nil
        }
    }

    extension Zoom {
        fileprivate func with(start: Double) -> Zoom {
            var z = self
            z.start = min(start, end - 2 * Zoom.ease)
            return z
        }

        fileprivate func with(end: Double) -> Zoom {
            var z = self
            z.end = max(end, start + 2 * Zoom.ease)
            return z
        }
    }

    private struct ZoomInspector: View {
        @Bindable var model: EditorModel
        let zoom: Zoom
        @State private var scale: Double?

        var body: some View {
            HStack(spacing: 12) {
                Text("Zoom \(EditorView.time(zoom.start))–\(EditorView.time(zoom.end))").font(.caption.bold())
                Slider(value: Binding(get: { scale ?? zoom.scale }, set: { scale = $0 }), in: Zoom.scales) { editing in
                    if !editing, let scale {
                        var z = zoom
                        z.scale = scale
                        model.session.update(z)
                        self.scale = nil
                    }
                }
                .frame(width: 160)
                Picker(
                    "Focus",
                    selection: Binding(
                        get: { zoom.focus == .cursor },
                        set: { follows in
                            var z = zoom
                            z.focus = follows ? .cursor : .point(model.session.cursorPosition(at: zoom.start))
                            model.session.update(z)
                        })
                ) {
                    Text("Follow cursor").tag(true)
                    Text("Fixed").tag(false)
                }
                .pickerStyle(.segmented).fixedSize()
                Spacer()
                Button("Delete Zoom", role: .destructive) {
                    model.session.removeZoom(zoom.id)
                    model.selectedZoom = nil
                }
            }
            .controlSize(.small)
        }
    }

    /// The transcript as words: click to select (⇧-click for a run), Cut removes them; cut words are struck through
    /// and clicking one restores it.
    private struct TranscriptPane: View {
        @Bindable var model: EditorModel
        @State private var anchor: Int?

        private var session: EditSession { model.session }

        var body: some View {
            if session.words.isEmpty {
                Text("No transcript. Turn on “Transcribe recordings” in Settings to cut by word.")
                    .font(.callout).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    WordFlow(spacing: 4) {
                        ForEach(session.words.indices, id: \.self) { i in
                            word(i)
                        }
                    }
                    .padding(10)
                }
            }
        }

        private func word(_ i: Int) -> some View {
            let cut = session.isCut(word: i)
            let selected = model.selectedWords.contains(i)
            let current = session.words[i].start <= model.playhead && model.playhead < session.words[i].end
            return Text(session.words[i].text)
                .strikethrough(cut)
                .foregroundStyle(cut ? .secondary : .primary)
                .padding(.horizontal, 2)
                .background(selected ? Color.accentColor.opacity(0.35) : current ? Color.yellow.opacity(0.3) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .onTapGesture {
                    let word = session.words[i]
                    if cut {
                        session.restore(TimeRange(start: word.start, end: word.end))
                    } else if NSEvent.modifierFlags.contains(.shift), let anchor {
                        model.selectedWords = Set(min(anchor, i)...max(anchor, i))
                    } else {
                        model.selectedWords = selected ? [] : [i]
                        anchor = i
                    }
                    model.selection = nil
                    model.seek(to: word.start)
                }
        }
    }

    /// Lays words out left to right, wrapping lines.
    private struct WordFlow: Layout {
        var spacing: Double

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let frames = place(subviews, width: proposal.width ?? 300)
            return CGSize(width: proposal.width ?? 300, height: frames.map(\.maxY).max() ?? 0)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for (subview, frame) in zip(subviews, place(subviews, width: bounds.width)) {
                subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
            }
        }

        private func place(_ subviews: Subviews, width: Double) -> [CGRect] {
            var frames: [CGRect] = []
            var x = 0.0
            var y = 0.0
            var line = 0.0
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x > 0, x + size.width > width {
                    x = 0
                    y += line + spacing
                    line = 0
                }
                frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
                x += size.width + spacing
                line = max(line, size.height)
            }
            return frames
        }
    }
#endif
