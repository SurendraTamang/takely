@preconcurrency import AVFoundation
import ProjectKit

/// What the finishing pass adds to an exported MP4.
struct MovieExtras {
    /// Chapter starts (seconds) and optional names ("Chapter n" when nil); a "Start" chapter is added at 0.
    var markers: [Marker] = []
    var captions: [CaptionCue] = []
    /// The captions' locale identifier, e.g. "en_US".
    var captionsLocale: String?
    var title: String?
    var summary: String?

    var isEmpty: Bool { markers.isEmpty && captions.isEmpty && title == nil && summary == nil }
}

/// Adds chapters, a caption track and title/description metadata to a finished MP4. `AVAssetExportSession` can't
/// write chapter or subtitle tracks, so the file is copied through `AVAssetReader` → `AVAssetWriter` without
/// re-encoding: chapters as a QuickTime text track associated to the video, captions as a 3GPP timed-text track.
enum MovieFinisher {
    enum Failure: Error { case unreadable, unwritable(String) }

    static func write(_ source: URL, to destination: URL, extras: MovieExtras) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks).filter { $0.mediaType == .video || $0.mediaType == .audio }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true  // keep the export's fast-start layout for sharing
        writer.metadata = metadata(title: extras.title, summary: extras.summary)

        var copies: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        var video: AVAssetWriterInput?
        for track in tracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.transform = try await track.load(.preferredTransform)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { throw Failure.unwritable("track \(track.trackID)") }
            reader.add(output)
            writer.add(input)
            copies.append((output, input))
            if track.mediaType == .video { video = input }
        }

        var sources = copies.map { SampleSource.reader($0.0) }
        var inputs = copies.map(\.1)
        if !extras.markers.isEmpty, let video {
            let format = try textFormat()
            let chapters = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
            chapters.marksOutputTrackAsEnabled = false
            // Players pick chapters by language; "und" matches no preferred language.
            let tag = chapterLanguage(extras)
            chapters.languageCode = tag.code
            chapters.extendedLanguageTag = tag.bcp47
            guard writer.canAdd(chapters) else { throw Failure.unwritable("chapter track") }
            writer.add(chapters)
            video.addTrackAssociation(withTrackOf: chapters, type: AVAssetTrack.AssociationType.chapterList.rawValue)
            sources.append(.samples(try chapterSamples(extras.markers, duration: duration, format: format)))
            inputs.append(chapters)
        }
        if !extras.captions.isEmpty {
            let format = try subtitleFormat()
            let captions = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
            captions.marksOutputTrackAsEnabled = false  // offered in the player's subtitle menu, off by default
            if let locale = extras.captionsLocale.map(Locale.init(identifier:)) {
                captions.languageCode = locale.language.languageCode?.identifier(.alpha3)
                captions.extendedLanguageTag = locale.identifier(.bcp47)
            }
            guard writer.canAdd(captions) else { throw Failure.unwritable("caption track") }
            writer.add(captions)
            sources.append(.samples(try captionSamples(extras.captions, duration: duration, format: format)))
            inputs.append(captions)
        }

        guard reader.startReading() else { throw reader.error ?? Failure.unreadable }
        guard writer.startWriting() else { throw writer.error ?? Failure.unwritable("start") }
        writer.startSession(atSourceTime: .zero)

        // Feed every track on its own queue at once: the writer interleaves them, so one waiting on another stalls.
        await withTaskGroup(of: Void.self) { group in
            for (index, (source, input)) in zip(sources, inputs).enumerated() {
                let pump = Pump(source: source, input: input)
                group.addTask { await pump.run(on: DispatchQueue(label: "app.takely.finish.\(index)")) }
            }
        }
        if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? writer.error ?? Failure.unreadable
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure.unwritable("finish") }
    }

    /// Named chapters (the AI's names, in the spoken language, or the person's own) take the recording's language;
    /// default names ("Chapter 2") are English.
    static func chapterLanguage(_ extras: MovieExtras) -> (code: String, bcp47: String) {
        guard extras.markers.contains(where: { $0.title?.trimmingCharacters(in: .whitespaces).isEmpty == false }),
            let locale = extras.captionsLocale.map(Locale.init(identifier:)),
            let code = locale.language.languageCode?.identifier(.alpha3)
        else { return ("eng", "en") }
        return (code, locale.identifier(.bcp47))
    }

    private static func metadata(title: String?, summary: String?) -> [AVMetadataItem] {
        [(AVMetadataIdentifier.commonIdentifierTitle, title), (.commonIdentifierDescription, summary)].compactMap { identifier, value in
            guard let value else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
    }

    /// Each chapter runs until the next one (the last until the end). Markers closer than 0.5 s are one chapter
    /// (a double press); text samples can't share a time.
    private static func chapterSamples(_ markers: [Marker], duration: CMTime, format: CMFormatDescription) throws -> [CMSampleBuffer] {
        // A marker at 0 (an AI name for the opening) titles the first chapter.
        var chapters = [Marker(t: 0, title: markers.first { $0.t < 0.05 }?.title ?? "Start")]
        for marker in markers.sorted(by: { $0.t < $1.t })
        where marker.t > 0.05 && marker.t < duration.seconds - 0.05 && marker.t - chapters.last!.t >= 0.5 {
            chapters.append(Marker(t: marker.t, title: marker.title ?? "Chapter \(chapters.count)"))
        }
        return try chapters.enumerated().map { index, chapter in
            let from = CMTime(seconds: chapter.t, preferredTimescale: 600)
            let to = index + 1 < chapters.count ? CMTime(seconds: chapters[index + 1].t, preferredTimescale: 600) : duration
            guard let sample = textSample(chapter.title ?? "", encd: true, from: from, duration: to - from, format: format) else {
                throw Failure.unwritable("chapter \(index)")
            }
            return sample
        }
    }

    /// Cues as timed-text samples, with empty samples filling the gaps so each cue disappears on time.
    private static func captionSamples(_ cues: [CaptionCue], duration: CMTime, format: CMFormatDescription) throws -> [CMSampleBuffer] {
        var samples: [CMSampleBuffer] = []
        var at = CMTime.zero
        func add(_ text: String, until end: CMTime) throws {
            guard end > at else { return }
            guard let sample = textSample(text, encd: false, from: at, duration: end - at, format: format) else {
                throw Failure.unwritable("caption")
            }
            samples.append(sample)
            at = end
        }
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            let start = CMTime(seconds: min(cue.start, duration.seconds), preferredTimescale: 600)
            let end = CMTime(seconds: min(cue.end, duration.seconds), preferredTimescale: 600)
            try add("", until: start)
            try add(cue.text, until: end)
        }
        try add("", until: duration)
        return samples
    }

    /// A text sample: a big-endian length and the UTF-8 text; QuickTime text adds an `encd` atom declaring UTF-8
    /// (3GPP timed text is UTF-8 by definition).
    private static func textSample(
        _ text: String, encd: Bool, from start: CMTime, duration: CMTime, format: CMFormatDescription
    ) -> CMSampleBuffer? {
        let utf8: [UInt8] = Array(text.utf8)
        var bytes: [UInt8] = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)]
        bytes += utf8
        if encd {
            bytes += [0, 0, 0, 12]
            bytes += Array("encd".utf8)
            bytes += [0, 0, 1, 0]
        }
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            bytes.withUnsafeBytes({
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
            })
                == noErr
        else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        return sample
    }

    /// A QuickTime `text` sample description, from its documented big-endian layout (the writer rejects a
    /// description built from an incomplete extensions dictionary).
    private static func textFormat() throws -> CMFormatDescription {
        func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        var body: [UInt8] = []
        body += [UInt8](repeating: 0, count: 6) + be16(1)  // reserved, data reference index
        body += be32(0) + be32(0)  // display flags, justification
        body += be16(0) + be16(0) + be16(0)  // background RGB
        body += be16(0) + be16(0) + be16(0) + be16(0)  // default text box
        // Default style (ScrpSTElement): start char, height, ascent, font, face + pad, size, colour.
        body += be32(0) + be16(0) + be16(0) + be16(1) + be16(0) + be16(12)
        body += be16(0xFFFF) + be16(0xFFFF) + be16(0xFFFF)
        body += [0]  // empty default font name (Pascal string)
        let bytes = be32(UInt32(8 + body.count)) + Array("text".utf8) + body
        var format: CMFormatDescription?
        let status = bytes.withUnsafeBufferPointer {
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: nil, bigEndianTextDescriptionData: $0.baseAddress!, size: $0.count, flavor: nil, mediaType: kCMMediaType_Text,
                formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw Failure.unwritable("text format \(status)") }
        return format
    }
}

extension MovieFinisher {
    /// A 3GPP timed-text (`tx3g`) sample entry (3GPP TS 26.245): bottom-centred white text, one font.
    fileprivate static func subtitleFormat() throws -> CMFormatDescription {
        func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        let font = Array("Sans-Serif".utf8)
        var body: [UInt8] = []
        body += [UInt8](repeating: 0, count: 6) + be16(1)  // reserved, data reference index
        body += be32(0)  // display flags
        body += [1, 0xFF]  // horizontal: centre, vertical: bottom
        body += [0, 0, 0, 0]  // background RGBA
        body += be16(0) + be16(0) + be16(0) + be16(0)  // default text box
        body += be16(0) + be16(0) + be16(1) + [0, 18] + [255, 255, 255, 255]  // style: chars, font 1, face, size, RGBA
        body += be32(UInt32(8 + 2 + 2 + 1 + font.count)) + Array("ftab".utf8) + be16(1) + be16(1) + [UInt8(font.count)] + font
        let bytes = be32(UInt32(8 + body.count)) + Array("tx3g".utf8) + body
        var format: CMFormatDescription?
        let status = bytes.withUnsafeBufferPointer {
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: nil, bigEndianTextDescriptionData: $0.baseAddress!, size: $0.count, flavor: nil,
                mediaType: kCMMediaType_Subtitle, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw Failure.unwritable("subtitle format \(status)") }
        return format
    }
}

/// Where a pump's samples come from.
private enum SampleSource {
    case reader(AVAssetReaderTrackOutput)
    case samples([CMSampleBuffer])
}

/// Moves one track's samples into its writer input whenever the writer is ready.
/// `@unchecked Sendable`: its state is only touched on the serial queue passed to `run`.
private final class Pump: @unchecked Sendable {
    private let source: SampleSource
    private let input: AVAssetWriterInput
    private var next = 0

    init(source: SampleSource, input: AVAssetWriterInput) {
        self.source = source
        self.input = input
    }

    func run(on queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            input.requestMediaDataWhenReady(on: queue) {
                while self.input.isReadyForMoreMediaData {
                    guard let sample = self.nextSample(), self.input.append(sample) else {
                        self.input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    private func nextSample() -> CMSampleBuffer? {
        switch source {
        case .reader(let output):
            return output.copyNextSampleBuffer()
        case .samples(let samples):
            defer { next += 1 }
            return next < samples.count ? samples[next] : nil
        }
    }
}
