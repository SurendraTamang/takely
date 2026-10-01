import AVFoundation
import ProjectKit
import SwiftUI

/// The blur review: each blurred area of a recording (found secrets and the user's own) with an on/off switch, a way
/// to add an area, and Re-export.
@MainActor @Observable
final class BlurReviewModel {
    let bundle: ProjectBundle
    var redactions: [Redaction] = []
    /// Why `redactions.json` couldn't be read: saving is then off, so it isn't replaced with an empty list.
    let loadError: String?
    let duration: Double
    var thumbnails: [UUID: CGImage] = [:]
    /// Adding an area: the frame shown and its time.
    var addTime = 0.0
    var addFrame: CGImage?
    private let segments: [Project.Segment]

    init(bundle: ProjectBundle) {
        self.bundle = bundle
        do {
            redactions = try bundle.readRedactions()
            loadError = nil
        } catch {
            loadError = "Couldn't read this recording's blurred areas: \(error.localizedDescription)"
        }
        let project = try? bundle.readProject()
        duration = project?.duration ?? 0
        segments = project?.segments ?? []
    }

    func loadThumbnails() async {
        for redaction in redactions where thumbnails[redaction.id] == nil {
            guard let t = redaction.track.first?.t else { continue }
            thumbnails[redaction.id] = await frame(at: t, size: CGSize(width: 320, height: 180))
        }
    }

    func showFrame(at t: Double) async {
        addTime = t
        let image = await frame(at: t, size: CGSize(width: 1280, height: 720))
        if addTime == t { addFrame = image }  // a later request already replaced it
    }

    /// Blurs `rect` from `start` to the end of the recording.
    func add(_ rect: NormalizedRect, from start: Double) {
        redactions.append(
            Redaction(kind: .manual, preview: "Area", track: [.init(t: start, rect: rect), .init(t: max(start, duration), rect: rect)]))
        if let addFrame { thumbnails[redactions[redactions.count - 1].id] = addFrame }
    }

    /// Writes the list, unless there's nothing to write and no file yet: the scan (which runs only when there's no
    /// file) then gets another chance on the next export.
    func save() throws {
        guard !redactions.isEmpty || FileManager.default.fileExists(atPath: bundle.redactionsURL.path) else { return }
        try bundle.write(redactions)
    }

    /// The screen at edited time `t` (segments play back to back).
    private func frame(at t: Double, size: CGSize) async -> CGImage? {
        var offset = 0.0
        for segment in segments {
            defer { offset += segment.duration }
            guard t < offset + segment.duration || segment == segments.last else { continue }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: bundle.segmentURL(segment.file)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = size
            let local = min(max(0, t - offset), max(0, segment.duration - 0.05))
            return try? await generator.image(at: CMTime(seconds: local, preferredTimescale: 600)).image
        }
        return nil
    }
}

struct BlurReviewView: View {
    @Bindable var model: BlurReviewModel
    /// Starts the export; returns why it can't, if it can't.
    let reexport: () -> String?
    @State private var adding = false
    @State private var fromHere = false
    /// The area being drawn, normalized to the frame.
    @State private var drag: NormalizedRect?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.redactions.isEmpty && !adding {
                Text("Nothing is blurred in this recording.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else if !adding {
                List($model.redactions) { $redaction in row($redaction) }
                    .frame(minHeight: 240)
            }
            if adding { addArea }
            if let error = error ?? model.loadError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(adding ? "Cancel" : "Add Blur Area…") {
                    adding.toggle()
                    drag = nil
                    if adding { Task { await model.showFrame(at: model.addTime) } }
                }
                Spacer()
                Button("Re-export") {
                    do {
                        try model.save()
                        error = reexport()
                    } catch {
                        self.error = "Couldn't save: \(error.localizedDescription)"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(adding || model.loadError != nil)
            }
        }
        .padding()
        .frame(width: 560)
        .task { await model.loadThumbnails() }
    }

    private func row(_ redaction: Binding<Redaction>) -> some View {
        let value = redaction.wrappedValue
        return HStack(spacing: 12) {
            FrameWithBox(image: model.thumbnails[value.id], box: value.track.first?.rect)
                .frame(width: 128, height: 72)
            VStack(alignment: .leading) {
                Text(Self.label(value.kind)).font(.headline)
                Text(value.preview).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(Self.time(value.track.first?.t ?? 0)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Blur", isOn: redaction.enabled).toggleStyle(.switch).labelsHidden()
        }
    }

    private var addArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drag over the area to blur.").font(.caption).foregroundStyle(.secondary)
            FrameWithBox(image: model.addFrame, box: drag)
                .overlay {
                    GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 2).onChanged { value in
                                    let size = geometry.size
                                    let a = CGPoint(x: value.startLocation.x / size.width, y: value.startLocation.y / size.height)
                                    let b = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                                    let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                                        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                                    drag =
                                        rect.isNull
                                        ? nil : NormalizedRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
                                })
                    }
                }
                .frame(maxHeight: 300)
            HStack {
                Text(Self.time(model.addTime)).monospacedDigit().font(.caption)
                Slider(
                    value: Binding(get: { model.addTime }, set: { t in Task { await model.showFrame(at: t) } }),
                    in: 0...max(model.duration, 0.1))
            }
            HStack {
                Picker("", selection: $fromHere) {
                    Text("Whole recording").tag(false)
                    Text("From this time on").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Button("Add") {
                    guard let drag else { return }
                    model.add(drag, from: fromHere ? model.addTime : 0)
                    self.drag = nil
                    adding = false
                }
                .disabled((drag?.width ?? 0) < 0.01 || (drag?.height ?? 0) < 0.01)
            }
        }
    }

    static func label(_ kind: Redaction.Kind) -> String {
        switch kind {
        case .apiKey: "API key or token"
        case .email: "Email address"
        case .card: "Card number"
        case .manual: "Blur area"
        }
    }

    static func time(_ t: Double) -> String { Duration.seconds(t).formatted(.time(pattern: .minuteSecond)) }
}

/// A frame (at its own aspect ratio) with an optional box (normalized, origin top-left) outlined on it.
private struct FrameWithBox: View {
    let image: CGImage?
    let box: NormalizedRect?

    var body: some View {
        ZStack {
            Rectangle().fill(.black)
            if let image { Image(decorative: image, scale: 1).resizable() }
        }
        .aspectRatio(image.map { Double($0.width) / Double(max($0.height, 1)) } ?? 16 / 9, contentMode: .fit)
        .overlay {
            if let box {
                GeometryReader { geometry in
                    Rectangle().fill(.white.opacity(0.2)).border(.yellow, width: 2)
                        .frame(width: box.width * geometry.size.width, height: box.height * geometry.size.height)
                        .offset(x: box.x * geometry.size.width, y: box.y * geometry.size.height)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
