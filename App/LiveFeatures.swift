import AppKit
import CaptureKit
import CoreMedia
import Observation

/// What the live voice features show: the prompter's spoken position and the coach. Plain app state, so the open
/// source build (without Takely Pro) shows nothing.
@MainActor @Observable
final class LiveStatus {
    /// Characters of the script spoken so far; nil when the prompter isn't following the voice.
    var spokenCharacters: Int?
    var wordsPerMinute: Int?
    /// Under 110 / over 170 wpm.
    var paceIsOff = false
    var fillers = 0
    var isSilent = false
    var coaching = false

    func reset() {
        spokenCharacters = nil
        wordsPerMinute = nil
        paceIsOff = false
        fillers = 0
        isSilent = false
        coaching = false
    }
}

#if canImport(TakelyPro)
    import TakelyPro

    /// Takely Pro's live recognition, connected to a recording (or a practice run) and mirrored into `LiveStatus`.
    @MainActor
    final class LiveFeatures {
        let status = LiveStatus()
        private var session: LiveSession?
        private var router: FrameRouter?
        private var practicing = false

        var isPracticing: Bool { practicing }

        /// Starts listening to `router`'s microphone while recording. `script` is followed if given.
        func startRecording(router: FrameRouter, script: String?, coach: Bool) async {
            await stop()
            guard script != nil || coach else { return }
            let session = LiveSession(script: script)
            guard await session.start() else { return }
            self.session = session
            self.router = router
            router.setMicListener { [session] audio in session.feed(audio) }
            status.coaching = coach
            if script != nil { status.spokenCharacters = 0 }
            mirror()
        }

        /// Practice: follows the voice from the microphone without recording.
        func startPractice(script: String) async -> Bool {
            await stop()
            let session = LiveSession(script: script)
            guard await session.startPractice() else { return false }
            self.session = session
            practicing = true
            status.spokenCharacters = 0
            mirror()
            return true
        }

        /// After a retake removed `seconds` of the recording: the prompter goes back to where the reader was.
        func rewind(by seconds: Double) {
            session?.rewind(to: CMClockGetTime(CMClockGetHostTimeClock()).seconds - seconds)
        }

        /// Stops listening; returns the coach's recap if there was enough speech.
        @discardableResult
        func stop() async -> String? {
            router?.setMicListener(nil)
            router = nil
            practicing = false
            let recap = await session?.stop()
            let coached = status.coaching
            session = nil
            status.reset()
            return coached ? recap : nil
        }

        private func mirror() {
            guard let session else { return }
            withObservationTracking {
                if status.spokenCharacters != nil { status.spokenCharacters = session.spokenCharacters }
                status.wordsPerMinute = session.wordsPerMinute
                status.paceIsOff = session.pace.map { $0 != .good } ?? false
                status.fillers = session.fillers
                status.isSilent = session.isSilent
            } onChange: {
                Task { @MainActor [weak self] in self?.mirror() }
            }
        }
    }
#else
    /// The open-source build: no live recognition.
    @MainActor
    final class LiveFeatures {
        let status = LiveStatus()
        var isPracticing: Bool { false }
        func startRecording(router: FrameRouter, script: String?, coach: Bool) async {}
        func startPractice(script: String) async -> Bool { false }
        func rewind(by seconds: Double) {}
        @discardableResult func stop() async -> String? { nil }
    }
#endif
