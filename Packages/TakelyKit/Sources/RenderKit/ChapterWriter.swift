@preconcurrency import AVFoundation
import ProjectKit

/// Adds a QuickTime chapter track ("Start", "Chapter 1", …) to a finished MP4. `AVAssetExportSession` can't write
/// one, so the file is copied through `AVAssetReader` → `AVAssetWriter` without re-encoding, with a text track
/// associated to the video as its chapter list.
enum ChapterWriter {
    enum Failure: Error { case unreadable, unwritable(String) }

    /// Writes `source` plus chapters at `markers` (seconds) to `destination`.
    static func write(_ source: URL, to destination: URL, markers: [Marker]) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks).filter { $0.mediaType == .video || $0.mediaType == .audio }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)

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

        let format = try textFormat()
        let chapters = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
        chapters.marksOutputTrackAsEnabled = false
        // Players pick chapters by language; "und" matches no preferred language. Titles are English ("Chapter 1").
        chapters.languageCode = "eng"
        chapters.extendedLanguageTag = "en"
        guard let video, writer.canAdd(chapters) else { throw Failure.unwritable("chapter track") }
        writer.add(chapters)
        video.addTrackAssociation(withTrackOf: chapters, type: AVAssetTrack.AssociationType.chapterList.rawValue)

        guard reader.startReading() else { throw reader.error ?? Failure.unreadable }
        guard writer.startWriting() else { throw writer.error ?? Failure.unwritable("start") }
        writer.startSession(atSourceTime: .zero)

        // Each chapter runs until the next one (the last until the end).
        let starts = [0] + markers.map(\.t).filter { $0 > 0.05 && $0 < duration.seconds - 0.05 }.sorted()
        var samples: [CMSampleBuffer] = []
        for (index, start) in starts.enumerated() {
            let from = CMTime(seconds: start, preferredTimescale: 600)
            let to = index + 1 < starts.count ? CMTime(seconds: starts[index + 1], preferredTimescale: 600) : duration
            guard let sample = textSample(index == 0 ? "Start" : "Chapter \(index)", from: from, duration: to - from, format: format)
            else { throw Failure.unwritable("chapter \(index)") }
            samples.append(sample)
        }

        // Feed every track on its own queue at once: the writer interleaves them, so one waiting on another stalls.
        let sources = copies.map { SampleSource.reader($0.0) } + [.samples(samples)]
        let inputs = copies.map(\.1) + [chapters]
        await withTaskGroup(of: Void.self) { group in
            for (index, (source, input)) in zip(sources, inputs).enumerated() {
                let pump = Pump(source: source, input: input)
                group.addTask { await pump.run(on: DispatchQueue(label: "app.takely.chapters.\(index)")) }
            }
        }
        if reader.status == .failed { throw reader.error ?? Failure.unreadable }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure.unwritable("finish") }
    }

    /// QuickTime text sample: a big-endian length, the UTF-8 text, and an `encd` atom declaring UTF-8.
    private static func textSample(_ text: String, from start: CMTime, duration: CMTime, format: CMFormatDescription) -> CMSampleBuffer? {
        let utf8: [UInt8] = Array(text.utf8)
        var bytes: [UInt8] = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)]
        bytes += utf8
        bytes += [0, 0, 0, 12]
        bytes += Array("encd".utf8)
        bytes += [0, 0, 1, 0]
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
