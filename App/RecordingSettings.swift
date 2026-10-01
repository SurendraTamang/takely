import CaptureKit
import CoreGraphics
import Foundation
import Observation
import ProjectKit

/// Everything a recording starts from, persisted so ⌥⇧R works before the panel has ever been opened.
@MainActor @Observable
final class RecordingSettings {
    private let defaults: UserDefaults

    var displayID: CGDirectDisplayID? {
        didSet { defaults.set(displayID.map { Int($0) }, forKey: Key.displayID) }
    }
    var camera: Bool { didSet { defaults.set(camera, forKey: Key.camera) } }
    var systemAudio: Bool { didSet { defaults.set(systemAudio, forKey: Key.systemAudio) } }
    var microphone: Bool { didSet { defaults.set(microphone, forKey: Key.microphone) } }
    var removeEcho: Bool { didSet { defaults.set(removeEcho, forKey: Key.removeEcho) } }
    var resolution: Resolution { didSet { defaults.set(resolution.rawValue, forKey: Key.resolution) } }
    var fps: Int { didSet { defaults.set(fps, forKey: Key.fps) } }
    var codec: VideoCodec { didSet { defaults.set(codec.rawValue, forKey: Key.codec) } }
    var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Key.saveFolder) } }
    var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: Key.hasOnboarded) } }
    var target: CaptureTarget { didSet { defaults.set(target.rawValue, forKey: Key.target) } }
    /// The last region, in global points (origin top-left); offered again by the region picker.
    var region: CGRect? { didSet { defaults.set(region.map { [$0.minX, $0.minY, $0.width, $0.height] }, forKey: Key.region) } }
    /// `AVCaptureDevice.uniqueID`s; nil means the system default.
    var microphoneID: String? { didSet { defaults.set(microphoneID, forKey: Key.microphoneID) } }
    var cameraID: String? { didSet { defaults.set(cameraID, forKey: Key.cameraID) } }
    var countdown: Bool { didSet { defaults.set(countdown, forKey: Key.countdown) } }
    var showControls: Bool { didSet { defaults.set(showControls, forKey: Key.showControls) } }
    var bubbleShape: BubbleShape { didSet { defaults.set(bubbleShape.rawValue, forKey: Key.bubbleShape) } }
    /// Bubble diameter in points on screen.
    var bubbleDiameter: Double { didSet { defaults.set(bubbleDiameter, forKey: Key.bubbleDiameter) } }
    /// Bubble and control bar positions (AppKit screen coordinates), nil until moved.
    var bubbleOrigin: CGPoint? { didSet { defaults.set(bubbleOrigin.map { [$0.x, $0.y] }, forKey: Key.bubbleOrigin) } }
    var prompterScript: String { didSet { defaults.set(prompterScript, forKey: Key.prompterScript) } }
    var prompterWordsPerMinute: Double { didSet { defaults.set(prompterWordsPerMinute, forKey: Key.prompterWordsPerMinute) } }
    var prompterFontSize: Double { didSet { defaults.set(prompterFontSize, forKey: Key.prompterFontSize) } }
    var prompterOpacity: Double { didSet { defaults.set(prompterOpacity, forKey: Key.prompterOpacity) } }
    var prompterMirrored: Bool { didSet { defaults.set(prompterMirrored, forKey: Key.prompterMirrored) } }
    /// The prompter scrolls while recording and stops when paused or stopped.
    var prompterFollowsRecording: Bool { didSet { defaults.set(prompterFollowsRecording, forKey: Key.prompterFollowsRecording) } }
    /// Takely Pro: transcript and captions, the AI title/summary, and captions drawn into the video.
    var transcribe: Bool { didSet { defaults.set(transcribe, forKey: Key.transcribe) } }
    var aiSummary: Bool { didSet { defaults.set(aiSummary, forKey: Key.aiSummary) } }
    /// Takely Pro: the prompter follows the voice; the live coach shows pace and fillers while recording.
    var prompterFollowsVoice: Bool { didSet { defaults.set(prompterFollowsVoice, forKey: Key.prompterFollowsVoice) } }
    var liveCoach: Bool { didSet { defaults.set(liveCoach, forKey: Key.liveCoach) } }
    /// Takely Pro: keys, emails and card numbers seen on screen are blurred in the export.
    var redactSecrets: Bool { didSet { defaults.set(redactSecrets, forKey: Key.redactSecrets) } }
    /// Takely Pro: zoom in on bursts of clicks; cut long pauses where nothing happens on screen (both off: exports
    /// shouldn't change unexpectedly).
    var autoZoom: Bool { didSet { defaults.set(autoZoom, forKey: Key.autoZoom) } }
    var removeSilences: Bool { didSet { defaults.set(removeSilences, forKey: Key.removeSilences) } }
    /// `takely://` links run without asking (any web page or app can open a link, so off by default).
    var allowLinkControl: Bool { didSet { defaults.set(allowLinkControl, forKey: Key.allowLinkControl) } }
    var burnInCaptions: Bool { didSet { defaults.set(burnInCaptions, forKey: Key.burnInCaptions) } }
    var controlsOrigin: CGPoint? { didSet { defaults.set(controlsOrigin.map { [$0.x, $0.y] }, forKey: Key.controlsOrigin) } }

    static let defaultSaveFolder = URL.moviesDirectory.appending(path: "Takely", directoryHint: .isDirectory)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayID = (defaults.object(forKey: Key.displayID) as? Int).map { CGDirectDisplayID($0) }
        camera = defaults.object(forKey: Key.camera) as? Bool ?? false
        systemAudio = defaults.object(forKey: Key.systemAudio) as? Bool ?? true
        microphone = defaults.object(forKey: Key.microphone) as? Bool ?? true
        removeEcho = defaults.object(forKey: Key.removeEcho) as? Bool ?? true
        resolution = defaults.string(forKey: Key.resolution).flatMap(Resolution.init(rawValue:)) ?? .p1080
        fps = defaults.object(forKey: Key.fps) as? Int ?? 30
        codec = defaults.string(forKey: Key.codec).flatMap(VideoCodec.init(rawValue:)) ?? .hevc
        saveFolder =
            defaults.string(forKey: Key.saveFolder).map { URL(filePath: $0, directoryHint: .isDirectory) } ?? Self.defaultSaveFolder
        hasOnboarded = defaults.bool(forKey: Key.hasOnboarded)
        target = defaults.string(forKey: Key.target).flatMap(CaptureTarget.init(rawValue:)) ?? .display
        region = (defaults.array(forKey: Key.region) as? [Double]).flatMap {
            $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil
        }
        microphoneID = defaults.string(forKey: Key.microphoneID)
        cameraID = defaults.string(forKey: Key.cameraID)
        countdown = defaults.object(forKey: Key.countdown) as? Bool ?? true
        showControls = defaults.object(forKey: Key.showControls) as? Bool ?? true
        bubbleShape = defaults.string(forKey: Key.bubbleShape).flatMap(BubbleShape.init(rawValue:)) ?? .circle
        bubbleDiameter = defaults.object(forKey: Key.bubbleDiameter) as? Double ?? 180
        bubbleOrigin = (defaults.array(forKey: Key.bubbleOrigin) as? [Double]).flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        prompterScript = defaults.string(forKey: Key.prompterScript) ?? ""
        prompterWordsPerMinute = defaults.object(forKey: Key.prompterWordsPerMinute) as? Double ?? 140
        prompterFontSize = defaults.object(forKey: Key.prompterFontSize) as? Double ?? 32
        prompterOpacity = defaults.object(forKey: Key.prompterOpacity) as? Double ?? 0.75
        prompterMirrored = defaults.bool(forKey: Key.prompterMirrored)
        prompterFollowsRecording = defaults.object(forKey: Key.prompterFollowsRecording) as? Bool ?? true
        transcribe = defaults.object(forKey: Key.transcribe) as? Bool ?? true
        aiSummary = defaults.object(forKey: Key.aiSummary) as? Bool ?? true
        prompterFollowsVoice = defaults.object(forKey: Key.prompterFollowsVoice) as? Bool ?? true
        liveCoach = defaults.object(forKey: Key.liveCoach) as? Bool ?? true
        burnInCaptions = defaults.bool(forKey: Key.burnInCaptions)
        autoZoom = defaults.bool(forKey: Key.autoZoom)
        removeSilences = defaults.bool(forKey: Key.removeSilences)
        allowLinkControl = defaults.bool(forKey: Key.allowLinkControl)
        redactSecrets = defaults.object(forKey: Key.redactSecrets) as? Bool ?? true
        controlsOrigin = (defaults.array(forKey: Key.controlsOrigin) as? [Double]).flatMap {
            $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil
        }
    }

    private enum Key {
        static let displayID = "displayID"
        static let camera = "camera"
        static let systemAudio = "systemAudio"
        static let microphone = "microphone"
        static let removeEcho = "removeEcho"
        static let resolution = "resolution"
        static let fps = "fps"
        static let codec = "codec"
        static let saveFolder = "saveFolder"
        static let target = "target"
        static let region = "region"
        static let microphoneID = "microphoneID"
        static let cameraID = "cameraID"
        static let countdown = "countdown"
        static let showControls = "showControls"
        static let bubbleShape = "bubbleShape"
        static let bubbleDiameter = "bubbleDiameter"
        static let bubbleOrigin = "bubbleOrigin"
        static let controlsOrigin = "controlsOrigin"
        static let transcribe = "transcribe"
        static let aiSummary = "aiSummary"
        static let prompterFollowsVoice = "prompterFollowsVoice"
        static let liveCoach = "liveCoach"
        static let burnInCaptions = "burnInCaptions"
        static let redactSecrets = "redactSecrets"
        static let allowLinkControl = "allowLinkControl"
        static let autoZoom = "autoZoom"
        static let removeSilences = "removeSilences"
        static let prompterScript = "prompterScript"
        static let prompterWordsPerMinute = "prompterWordsPerMinute"
        static let prompterFontSize = "prompterFontSize"
        static let prompterOpacity = "prompterOpacity"
        static let prompterMirrored = "prompterMirrored"
        static let prompterFollowsRecording = "prompterFollowsRecording"
        static let hasOnboarded = "hasOnboarded"
    }
}
