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
    /// A recording is in progress (Practice is then unavailable). Set from the recording's phase.
    var recording = false
    /// Why voice features aren't running, if they can't (shown in the prompter).
    var note: String?

    func reset() {
        note = nil
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
    /// Starts and stops can overlap (a stop while the model loads, a restart): each start belongs to a generation,
    /// and a start that finishes after a newer start or stop shuts its session down instead of installing it.
    @MainActor
    final class LiveFeatures {
        let status = LiveStatus()
        private var session: LiveSession?
        private var router: FrameRouter?
        private var generation = 0

        /// Starts listening to `router`'s microphone while recording. `script` is followed if given.
        func startRecording(router: FrameRouter, script: String?, coach: Bool, locale: Locale) async {
            let generation = detachAndStop()
            guard script != nil || coach else { return }
            let session = LiveSession(script: script)
            let started = await session.start(locale: locale)
            guard started, generation == self.generation else {
                if generation == self.generation { status.note = session.note }  // not when superseded
                await session.stop()
                return
            }
            status.coaching = coach
            install(session, following: script != nil)
            self.router = router
            router.setMicListener { [session] audio in session.feed(audio) }
        }

        /// Practice: follows the voice from the microphone without recording. False if it couldn't start; nil if a
        /// newer start or stop superseded it (the caller then has nothing to undo).
        func startPractice(script: String, microphoneID: String?, locale: Locale) async -> Bool? {
            let generation = detachAndStop()
            let session = LiveSession(script: script)
            let started = await session.startPractice(microphoneID: microphoneID, locale: locale)
            guard generation == self.generation else {
                await session.stop()
                return nil
            }
            guard started else {
                status.note = session.note
                await session.stop()
                return false
            }
            install(session, following: true)
            return true
        }

        /// After a retake cut back to host time `time`: the prompter goes back to where the reader was then.
        func rewind(to time: Double) { session?.rewind(to: time) }

        /// Stops listening; returns the coach's recap if there was enough speech.
        @discardableResult
        func stop() async -> String? {
            let coached = status.coaching
            let old = session
            _ = detach()
            let recap = await old?.stop()
            return coached ? recap : nil
        }

        /// Ends the current session at once (its analyzer finishes in the background) and starts a new generation.
        private func detachAndStop() -> Int {
            if let old = detach() { Task { await old.stop() } }
            return generation
        }

        private func detach() -> LiveSession? {
            generation += 1
            router?.setMicListener(nil)
            router = nil
            let old = session
            session = nil
            status.reset()
            return old
        }

        private func install(_ session: LiveSession, following: Bool) {
            self.session = session
            status.note = nil
            status.spokenCharacters = following ? 0 : nil
            mirror(session, following: following)
        }

        /// Copies the session's state into `status` while it's the current one. Only the session is observed
        /// (reading `status` here would make these writes re-trigger it).
        private func mirror(_ session: LiveSession, following: Bool) {
            guard session === self.session else { return }
            withObservationTracking {
                if following { status.spokenCharacters = session.spokenCharacters }
                status.wordsPerMinute = session.wordsPerMinute
                status.paceIsOff = session.pace.map { $0 != .good } ?? false
                status.fillers = session.fillers
                status.isSilent = session.isSilent
            } onChange: {
                Task { @MainActor [weak self, weak session] in
                    if let session { self?.mirror(session, following: following) }
                }
            }
        }
    }
#else
    /// The open-source build: no live recognition.
    @MainActor
    final class LiveFeatures {
        let status = LiveStatus()
        func startRecording(router: FrameRouter, script: String?, coach: Bool, locale: Locale) async {}
        func startPractice(script: String, microphoneID: String?, locale: Locale) async -> Bool? { false }
        func rewind(to time: Double) {}
        @discardableResult func stop() async -> String? { nil }
    }
#endif
