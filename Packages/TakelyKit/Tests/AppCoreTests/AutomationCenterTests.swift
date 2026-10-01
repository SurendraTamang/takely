import CoreGraphics
import Foundation
import TakelyControl
import Testing

@testable import AppCore

@MainActor
final class FakeHost: AutomationHost {
    var phase = RecordingController.Phase.idle
    var isBusy = false
    var errorMessage: String?
    var lastRecording: URL?
    var startFails = false
    var exportFails = false
    var started: (countdown: Bool?, region: CGRect?)?

    func startRecording(countdown: Bool?, region: CGRect?) async {
        started = (countdown, region)
        if startFails { errorMessage = "Screen Recording permission missing." } else { phase = .recording }
    }

    var stopThrows = false
    func stopRecording() async {
        phase = .idle
        if stopThrows {
            errorMessage = "Couldn't stop: the disk went away"
        } else if exportFails {
            lastRecording = URL(filePath: "/Movies/a.takely")
            errorMessage = "Recording saved, but export failed: disk full"
        } else {
            lastRecording = URL(filePath: "/Movies/a.takely/exports/a.mp4")
        }
    }

    func togglePause() async { phase = phase == .paused ? .recording : .paused }
    func addMarker() -> Bool { true }
    func retake() async -> Bool { false }
    var trashFails = false
    func discard() async {
        phase = .idle
        if trashFails { errorMessage = "Couldn't move the recording to the Trash." }
    }
}

@MainActor @Suite struct AutomationCenterTests {
    @Test func startStopReturnsTheVideo() async {
        let host = FakeHost()
        let center = AutomationCenter(host: host)
        let started = await center.perform(ControlRequest(.start, countdown: false, region: CGRect(x: 0, y: 0, width: 100, height: 80)))
        #expect(started.ok && started.state == "recording")
        #expect(host.started?.countdown == false && host.started?.region == CGRect(x: 0, y: 0, width: 100, height: 80))
        let again = await center.perform(ControlRequest(.start))
        #expect(!again.ok && again.error == "Already recording.")
        let stopped = await center.perform(ControlRequest(.stop))
        #expect(stopped.ok && stopped.path == "/Movies/a.takely/exports/a.mp4" && stopped.state == "idle")
        let stopAgain = await center.perform(ControlRequest(.stop))
        #expect(!stopAgain.ok && stopAgain.error == "Not recording.")
    }

    @Test func failuresSayWhy() async {
        let host = FakeHost()
        host.startFails = true
        let center = AutomationCenter(host: host)
        let start = await center.perform(ControlRequest(.start))
        #expect(!start.ok && start.error == "Screen Recording permission missing.")
        host.startFails = false
        host.exportFails = true
        _ = await center.perform(ControlRequest(.start))
        let stop = await center.perform(ControlRequest(.stop))
        #expect(!stop.ok && stop.error?.contains("export failed") == true && stop.path == "/Movies/a.takely")
    }

    @Test func pauseResumeMarkerRetakeDiscardCheckTheState() async {
        let host = FakeHost()
        let center = AutomationCenter(host: host)
        #expect(await center.perform(ControlRequest(.pause)).error == "Not recording.")
        #expect(await center.perform(ControlRequest(.marker)).error == "Not recording.")
        _ = await center.perform(ControlRequest(.start))
        #expect(await center.perform(ControlRequest(.resume)).error == "Not paused.")
        #expect(await center.perform(ControlRequest(.pause)).state == "paused")
        #expect(await center.perform(ControlRequest(.marker)).error == "Paused: resume first.")
        #expect(await center.perform(ControlRequest(.resume)).state == "recording")
        #expect(await center.perform(ControlRequest(.marker)).ok)
        #expect(await center.perform(ControlRequest(.retake)).error == "Nothing to take back.")
        let discarded = await center.perform(ControlRequest(.discard))
        #expect(discarded.ok && discarded.state == "idle")
        #expect(await center.perform(ControlRequest(.status)).ok)
    }

    @Test func refusesWhatItCantDoProperly() async {
        let host = FakeHost()
        let center = AutomationCenter(host: host)
        var bad = ControlRequest(.start)
        bad.region = [0, 0, -1, 5]
        let badRegion = await center.perform(bad)
        #expect(!badRegion.ok && host.started == nil)  // never falls back to recording the whole display
        host.phase = .starting
        host.isBusy = true
        #expect(await center.perform(ControlRequest(.stop)).error == AutomationCenter.starting)
        #expect(await center.perform(ControlRequest(.discard)).error == AutomationCenter.starting)
        host.phase = .recording
        host.isBusy = false
        host.lastRecording = URL(filePath: "/Movies/old.takely/exports/old.mp4")
        host.stopThrows = true
        let stop = await center.perform(ControlRequest(.stop))
        #expect(!stop.ok && stop.path == nil && stop.error == "Couldn't stop: the disk went away")  // not the old take
        host.phase = .recording
        host.trashFails = true
        #expect(await center.perform(ControlRequest(.discard)).ok == false)
        host.phase = .paused
        #expect(await center.perform(ControlRequest(.marker)).error == "Paused: resume first.")
    }
}
