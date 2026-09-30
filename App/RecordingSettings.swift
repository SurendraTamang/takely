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
        static let hasOnboarded = "hasOnboarded"
    }
}
