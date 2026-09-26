import Foundation
import ScreenCaptureKit
import AVFoundation
import Combine

class ScreenRecorder: NSObject, ObservableObject {
    // Published properties (main thread only)
    @MainActor @Published var isRecording = false
    @MainActor @Published var recordingDuration: TimeInterval = 0
    @MainActor @Published var availableDisplays: [SCDisplay] = []
    @MainActor @Published var selectedDisplay: SCDisplay?
    @MainActor @Published var captureSystemAudio = true
    @MainActor @Published var captureMicrophone = true
    @MainActor @Published var errorMessage: String?

    // Stream (accessed from multiple threads)
    private var stream: SCStream?

    // Asset Writer (protected by lock)
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // Timing (protected by lock)
    private var firstFrameTime: CMTime?
    private var isWritingStarted = false

    // Timer
    private var timer: Timer?
    private var recordingStartDate: Date?
    private var outputURL: URL?

    // Thread safety
    private let lock = NSLock()

    // Queues
    private let videoQueue = DispatchQueue(label: "com.screenrecorder.video")
    private let audioQueue = DispatchQueue(label: "com.screenrecorder.audio")

    override init() {
        super.init()
        Task { @MainActor in
            await refreshAvailableDisplays()
        }
    }

    @MainActor
    func refreshAvailableDisplays() async {
        do {
            let content = try await SCShareableContent.current
            availableDisplays = content.displays
            if selectedDisplay == nil {
                selectedDisplay = availableDisplays.first
            }
            if availableDisplays.isEmpty {
                errorMessage = "No displays found. Grant Screen Recording permission, then click Refresh."
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func startRecording() async {
        guard let display = selectedDisplay else {
            errorMessage = "No display selected"
            return
        }

        let shouldCaptureSystemAudio = captureSystemAudio
        let shouldCaptureMicrophone = captureMicrophone

        errorMessage = nil

        lock.lock()
        firstFrameTime = nil
        isWritingStarted = false
        lock.unlock()

        // Create output file
        let desktopPath = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let fileName = "Recording-\(dateFormatter.string(from: Date())).mov"
        let fileURL = desktopPath.appendingPathComponent(fileName)
        outputURL = fileURL

        try? FileManager.default.removeItem(at: fileURL)

        do {
            // Create asset writer
            let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mov)

            let videoWidth = display.width
            let videoHeight = display.height

            // Video settings
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: false
                ] as [String: Any]
            ]

            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true

            // Pixel buffer adaptor
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vInput,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )

            writer.add(vInput)

            // Audio settings
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]

            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            writer.add(aInput)

            lock.lock()
            assetWriter = writer
            videoInput = vInput
            audioInput = aInput
            pixelBufferAdaptor = adaptor
            lock.unlock()

            // Configure stream
            let filter = SCContentFilter(display: display, excludingWindows: [])

            let config = SCStreamConfiguration()
            config.width = videoWidth
            config.height = videoHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 8

            // Audio configuration
            if shouldCaptureSystemAudio || shouldCaptureMicrophone {
                config.capturesAudio = shouldCaptureSystemAudio
                config.sampleRate = 48000
                config.channelCount = 2
            }

            if shouldCaptureMicrophone {
                config.captureMicrophone = true
            }

            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            stream = newStream

            // Add stream outputs
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)

            if shouldCaptureSystemAudio {
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }

            if shouldCaptureMicrophone {
                try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
            }

            // Start writing and capture
            writer.startWriting()
            try await newStream.startCapture()

            isRecording = true
            recordingStartDate = Date()
            startTimer()

        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
            await cleanup()
        }
    }

    @MainActor
    func stopRecording() async {
        guard isRecording else { return }

        isRecording = false
        stopTimer()

        // Stop capture first
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                print("Stop capture error: \(error)")
            }
        }

        // Finalize writing
        lock.lock()
        let writer = assetWriter
        let vInput = videoInput
        let aInput = audioInput
        let url = outputURL
        lock.unlock()

        if let writer = writer {
            vInput?.markAsFinished()
            aInput?.markAsFinished()

            await writer.finishWriting()

            if writer.status == .completed, let url = url {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            } else if let error = writer.error {
                print("Writer error: \(error)")
                errorMessage = "Save failed: \(error.localizedDescription)"
            }
        }

        await cleanup()
        recordingDuration = 0
    }

    @MainActor
    private func cleanup() async {
        stream = nil

        lock.lock()
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        pixelBufferAdaptor = nil
        firstFrameTime = nil
        isWritingStarted = false
        lock.unlock()
    }

    @MainActor
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let startDate = self?.recordingStartDate {
                    self?.recordingDuration = Date().timeIntervalSince(startDate)
                }
            }
        }
    }

    @MainActor
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// MARK: - SCStreamDelegate
extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.errorMessage = "Stream error: \(error.localizedDescription)"
            self.isRecording = false
        }
    }
}

// MARK: - SCStreamOutput
extension ScreenRecorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        lock.lock()
        guard let writer = assetWriter, writer.status == .writing else {
            lock.unlock()
            return
        }
        let vInput = videoInput
        let aInput = audioInput
        let adaptor = pixelBufferAdaptor
        let firstTime = firstFrameTime
        let writingStarted = isWritingStarted
        lock.unlock()

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        switch type {
        case .screen:
            processVideoFrame(
                sampleBuffer,
                timestamp: timestamp,
                writer: writer,
                vInput: vInput,
                adaptor: adaptor,
                firstTime: firstTime,
                writingStarted: writingStarted
            )

        case .audio, .microphone:
            processAudioFrame(
                sampleBuffer,
                timestamp: timestamp,
                aInput: aInput,
                firstTime: firstTime,
                writingStarted: writingStarted
            )

        @unknown default:
            break
        }
    }

    nonisolated private func processVideoFrame(
        _ sampleBuffer: CMSampleBuffer,
        timestamp: CMTime,
        writer: AVAssetWriter,
        vInput: AVAssetWriterInput?,
        adaptor: AVAssetWriterInputPixelBufferAdaptor?,
        firstTime: CMTime?,
        writingStarted: Bool
    ) {
        // Validate frame status
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRaw = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        guard let vInput = vInput, let adaptor = adaptor else { return }

        // Start session on first frame
        var currentFirstTime = firstTime
        var currentWritingStarted = writingStarted

        if currentFirstTime == nil {
            lock.lock()
            if firstFrameTime == nil {
                firstFrameTime = timestamp
                writer.startSession(atSourceTime: .zero)
                isWritingStarted = true
            }
            currentFirstTime = firstFrameTime
            currentWritingStarted = isWritingStarted
            lock.unlock()
        }

        guard currentWritingStarted, let firstTime = currentFirstTime else { return }

        // Calculate relative time from first frame
        let relativeTime = CMTimeSubtract(timestamp, firstTime)

        // Append pixel buffer
        if vInput.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: relativeTime)
        }
    }

    nonisolated private func processAudioFrame(
        _ sampleBuffer: CMSampleBuffer,
        timestamp: CMTime,
        aInput: AVAssetWriterInput?,
        firstTime: CMTime?,
        writingStarted: Bool
    ) {
        // Check current state
        lock.lock()
        let currentFirstTime = firstFrameTime
        let currentWritingStarted = isWritingStarted
        lock.unlock()

        guard currentWritingStarted, let firstTime = currentFirstTime, let aInput = aInput else { return }

        // Calculate relative time
        let relativeTime = CMTimeSubtract(timestamp, firstTime)

        // Skip if audio comes before video started
        guard relativeTime.seconds >= 0 else { return }

        // Retime the audio sample buffer
        guard let retimedBuffer = retimeSampleBuffer(sampleBuffer, to: relativeTime) else {
            return
        }

        if aInput.isReadyForMoreMediaData {
            aInput.append(retimedBuffer)
        }
    }

    nonisolated private func retimeSampleBuffer(_ sampleBuffer: CMSampleBuffer, to newTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: newTime,
            decodeTimeStamp: .invalid
        )

        var newBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &newBuffer
        )

        return status == noErr ? newBuffer : nil
    }
}
