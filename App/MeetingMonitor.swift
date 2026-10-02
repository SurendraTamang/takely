import AppCore
import AppKit
import CoreAudio
import OSLog
import ScreenCaptureKit

/// Watches for calls (Zoom, Teams, Google Meet in a browser…) and offers to record them — or records them, when
/// "Always record meetings" is on. A meeting recording captures the meeting's window (or the display), without the
/// camera bubble or countdown, and stops when the call ends.
@MainActor
final class MeetingMonitor {
    private let settings: RecordingSettings
    private let controller: RecordingController
    private let session: LiveRecordingSession
    private let notifier: ReadyNotifier
    private var watcher = MeetingWatcher()
    private var poller: Task<Void, Never>?
    /// The meeting Takely is recording (it stops the recording when the call ends).
    private var recording: Meeting?
    private let log = Logger(subsystem: "app.takely", category: "meetings")

    init(settings: RecordingSettings, controller: RecordingController, session: LiveRecordingSession, notifier: ReadyNotifier) {
        self.settings = settings
        self.controller = controller
        self.session = session
        self.notifier = notifier
        notifier.onRecordMeeting = { [weak self] in Task { await self?.recordCurrent() } }
    }

    /// Polls every 2 s (a handful of cheap system queries).
    func start() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func check() {
        guard settings.detectMeetings else { return }
        switch watcher.update(Self.snapshot()) {
        case .started(let meeting):
            log.info("meeting started: \(meeting.service)")
            guard controller.phase == .idle, !controller.isBusy else { return }  // already recording something
            if settings.autoRecordMeetings {
                Task { await record(meeting) }
            } else {
                Task { await notifier.meetingDetected(meeting.service) }
            }
        case .ended(let meeting):
            log.info("meeting ended: \(meeting.service)")
            notifier.withdrawMeetingOffer()
            if recording != nil, controller.isRecording {
                Task { await controller.stop() }
            }
            recording = nil
        case nil:
            break
        }
    }

    /// The notification's Record action.
    private func recordCurrent() async {
        guard let meeting = watcher.current else { return }
        await record(meeting)
    }

    private func record(_ meeting: Meeting) async {
        guard controller.phase == .idle, !controller.isBusy else { return }
        if let id = meeting.windowID,
            let window = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false).windows
                .first(where: { $0.windowID == id })
        {
            session.target = .window(window)
        } else {
            session.target = .display
        }
        session.meetingMode = true
        recording = meeting
        await controller.start()
        if !controller.isRecording { recording = nil }
    }

    // MARK: The Mac's state

    static func snapshot() -> MeetingSnapshot {
        MeetingSnapshot(micUsers: micUsers(), windows: windows())
    }

    /// Bundle identifiers of the processes with an audio input running (Core Audio's process objects, macOS 14.4+).
    static func micUsers() -> Set<String> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        let own = Bundle.main.bundleIdentifier
        var users: Set<String> = []
        for id in ids {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            address.mSelector = kAudioProcessPropertyIsRunningInput
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &runningSize, &running) == noErr, running != 0 else { continue }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            address.mSelector = kAudioProcessPropertyBundleID
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &bundleSize, &bundle) == noErr,
                let name = bundle?.takeRetainedValue() as String?, name != own
            else { continue }
            // Helpers (com.google.Chrome.helper…) count as their app.
            users.insert(MeetingWatcher.owningApp(name))
        }
        return users
    }

    /// On-screen windows with titles (readable with Screen Recording permission, which Takely has).
    static func windows() -> [MeetingSnapshot.Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var bundles: [pid_t: String] = [:]
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, let id = info[kCGWindowNumber as String] as? UInt32,
                (info[kCGWindowLayer as String] as? Int) == 0
            else { return nil }
            let bundle = bundles[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            bundles[pid] = bundle
            guard let bundle else { return nil }
            return MeetingSnapshot.Window(bundleID: bundle, id: id, title: info[kCGWindowName as String] as? String ?? "")
        }
    }
}
