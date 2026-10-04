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
    /// The recording Takely started for the current call (its bundle): only that one is stopped when the call ends,
    /// never one the person started themselves.
    private var meetingBundle: URL?
    /// The call ended while its recording couldn't be stopped yet (busy): try again.
    private var stopPending = false
    /// A call that started while Takely was busy (exporting…): offered once it's free, if the call is still on.
    private var waitingOffer: Meeting?
    /// Record was asked for while the mic was briefly off (switching devices…): starts when it's back, dropped if the call ends.
    private var recordPending = false
    private let log = Logger(subsystem: "app.takely", category: "meetings")

    init(settings: RecordingSettings, controller: RecordingController, session: LiveRecordingSession, notifier: ReadyNotifier) {
        self.settings = settings
        self.controller = controller
        self.session = session
        self.notifier = notifier
        notifier.onRecordMeeting = { [weak self] in Task { await self?.recordCurrent() } }
    }

    /// Polls every 2 s (a few milliseconds of system queries).
    func start() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.check()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func check() {
        // The meeting recording is over (stopped by the person, or failed): forget it.
        if controller.phase == .idle, !controller.isBusy, meetingBundle != nil {
            meetingBundle = nil
            stopPending = false
            session.meetingMode = false
        }
        guard settings.detectMeetings else {
            watcher = MeetingWatcher()  // a call in progress when it's turned back on is a new one
            waitingOffer = nil
            recordPending = false
            return
        }
        if stopPending { stopMeetingRecording() }
        if let waiting = waitingOffer, controller.phase == .idle, !controller.isBusy {
            waitingOffer = nil
            if watcher.current == waiting { offer(waiting) }
        }
        let event = watcher.update(Self.snapshot())
        if recordPending, event == nil, watcher.current != nil, !watcher.isEnding {
            recordPending = false
            Task { await recordCurrent() }
        }
        switch event {
        case .started(let meeting):
            log.info("meeting started: \(meeting.service)")
            if controller.phase == .idle, !controller.isBusy { offer(meeting) } else { waitingOffer = meeting }
        case .ended(let meeting):
            log.info("meeting ended: \(meeting.service)")
            notifier.withdrawMeetingOffer()
            waitingOffer = nil
            recordPending = false
            stopPending = meetingBundle != nil
            stopMeetingRecording()
        case nil:
            break
        }
    }

    private func offer(_ meeting: Meeting) {
        if settings.autoRecordMeetings {
            Task { await record(meeting) }
        } else {
            Task { await notifier.meetingDetected(meeting.service) }
        }
    }

    /// Stops the recording Takely started for the call — only if that's the one running.
    private func stopMeetingRecording() {
        guard stopPending, let meetingBundle else { return stopPending = false }
        guard controller.recordingBundle?.url == meetingBundle, controller.isRecording else {
            if controller.phase == .idle { stopPending = false }  // already stopped
            return
        }
        guard !controller.isBusy else { return }  // retried on the next poll
        stopPending = false
        Task { await controller.stop() }
    }

    /// The notification's Record action.
    private func recordCurrent() async {
        guard let meeting = watcher.current else { return }
        await record(meeting)
    }

    private func record(_ meeting: Meeting) async {
        guard controller.phase == .idle, !controller.isBusy else { return }
        // The mic is off (a device switch, or the call ending): wait for it to come back rather than record a call that's over.
        guard !watcher.isEnding else { return recordPending = true }
        // The call's window if it's on screen; else the display.
        var window: SCWindow?
        if let id = meeting.windowID {
            window = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).windows.first {
                $0.windowID == id
            }
        }
        // The person may have started a recording meanwhile: leave it alone.
        guard controller.phase == .idle, !controller.isBusy, watcher.current == meeting else { return }
        guard !watcher.isEnding else { return recordPending = true }
        session.target = window.map { .window($0) } ?? .display
        session.meetingMode = true
        await controller.start()
        if controller.isRecording, let bundle = controller.recordingBundle {
            meetingBundle = bundle.url
        } else {
            session.meetingMode = false  // didn't start (or isn't ours): the next recording is an ordinary one
        }
    }

    // MARK: The Mac's state

    static func snapshot() -> MeetingSnapshot {
        let users = micUsers()
        return MeetingSnapshot(micUsers: users, windows: users.contains(where: MeetingWatcher.isCandidate) ? windows() : [])
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
            // As its app's, like the mic users: an installed web app's windows (com.google.Chrome.app.<id>) are Chrome's.
            let bundle = bundles[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(MeetingWatcher.owningApp)
            bundles[pid] = bundle
            guard let bundle else { return nil }
            return MeetingSnapshot.Window(bundleID: bundle, id: id, title: info[kCGWindowName as String] as? String ?? "")
        }
    }
}
