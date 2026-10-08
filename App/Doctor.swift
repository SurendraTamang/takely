import AVFoundation
import AppCore
import AppKit
import ApplicationServices
import EventKit
import FoundationModels
import UserNotifications

/// The checks behind `takely doctor`: what Takely depends on, as this copy of the app sees it (permissions belong to
/// the app, so only the app can tell).
@MainActor
enum Doctor {
    static func checks(settings: RecordingSettings, license: (status: DoctorCheck.Status, text: String)?) async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let privacy = "System Settings › Privacy & Security › "

        // Screen Recording: the one recording can't do without.
        checks.append(
            CGPreflightScreenCaptureAccess()
                ? DoctorCheck("Screen Recording", .ok, "allowed")
                : DoctorCheck(
                    "Screen Recording", .problem, "off for this copy of Takely",
                    fix: "Turn Takely on in \(privacy)Screen & System Audio Recording (if it's on already, remove it and "
                        + "add it again, or run `tccutil reset ScreenCapture app.takely.Takely`), then reopen Takely."))
        for (type, name, used) in [(AVMediaType.video, "Camera", settings.camera), (.audio, "Microphone", settings.microphone)] {
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .authorized: checks.append(DoctorCheck(name, .ok, "allowed"))
            case .notDetermined:
                checks.append(
                    DoctorCheck(name, .note, used ? "not asked yet (asked at the next recording)" : "not asked yet (off in Takely)"))
            default:
                checks.append(
                    DoctorCheck(
                        name, used ? .problem : .note, "not allowed" + (used ? "" : " (off in Takely)"),
                        fix: "Allow Takely in \(privacy)\(name), or turn the \(name.lowercased()) off in Takely."))
            }
        }
        checks.append(
            AXIsProcessTrusted()
                ? DoctorCheck("Accessibility (Demo Mode)", .ok, "allowed")
                : DoctorCheck(
                    "Accessibility (Demo Mode)", .note, "not allowed: Demo Mode can't click or type",
                    fix: "Allow Takely in \(privacy)Accessibility to use Demo Mode."))
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: checks.append(DoctorCheck("Notifications", .ok, "allowed"))
        case .notDetermined: checks.append(DoctorCheck("Notifications", .note, "not asked yet (asked after the first recording)"))
        default:
            checks.append(
                DoctorCheck(
                    "Notifications", .note, "off: Ready and failures show in the panel instead",
                    fix: "Allow them in System Settings › Notifications › Takely."))
        }
        if settings.nameMeetingsFromCalendar {
            checks.append(
                EKEventStore.authorizationStatus(for: .event) == .fullAccess
                    ? DoctorCheck("Calendar", .ok, "allowed (names meeting recordings)")
                    : DoctorCheck(
                        "Calendar", .problem, "naming meetings from Calendar is on, but access isn't allowed",
                        fix: "Allow Takely in \(privacy)Calendars, or turn the setting off."))
        }

        // Copies of the app: a permission switched on in System Settings can go to another copy with the same ID.
        let copies = (LSCopyApplicationURLsForBundleIdentifier("app.takely.Takely" as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []
        let others = copies.map(\.standardizedFileURL.path).filter { $0 != Bundle.main.bundleURL.standardizedFileURL.path }
        checks.append(
            others.isEmpty
                ? DoctorCheck("Copies of Takely", .ok, "only this one")
                : DoctorCheck(
                    "Copies of Takely", .note, "\(others.count) more registered: " + others.prefix(3).joined(separator: ", "),
                    fix: "Permissions you switch on may go to another copy: delete the ones you don't use (or unregister "
                        + "them: `lsregister -u <path>`)."))
        // Signing: ad-hoc builds lose their permissions at every rebuild.
        var code: SecStaticCode?
        var info: CFDictionary?
        if SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        {
            let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
            checks.append(
                team != nil
                    ? DoctorCheck("Signature", .ok, "team \(team!)")
                    : DoctorCheck(
                        "Signature", .note, "ad hoc (a local build): macOS forgets its permissions when it's rebuilt",
                        fix: "Sign local builds with an Apple Development certificate (README › Testing a local build)."))
        }

        // Where recordings go, and room for them.
        // A folder that doesn't exist yet (a fresh install) is made at the first recording: check where it would go.
        let folder = settings.saveFolder
        var existing = folder
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            existing = existing.deletingLastPathComponent()
        }
        let note = existing == folder ? "" : " (made at the first recording)"
        let values = try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if !FileManager.default.isWritableFile(atPath: existing.path) {
            checks.append(
                DoctorCheck(
                    "Save folder", .problem, "\(folder.path) can't be written to", fix: "Choose another folder in Settings › General."))
        } else if let free = values?.volumeAvailableCapacityForImportantUsage {
            let gigabytes = String(format: "%.0f", Double(free) / 1_000_000_000)
            checks.append(
                DoctorCheck(
                    "Save folder", free < StorageGuard.minimumFreeToStart ? .problem : .ok, "\(folder.path)\(note), \(gigabytes) GB free",
                    fix: "Free some space: Takely won't start a recording with less than 2 GB free."))
        }

        // Apple Intelligence (AI titles and summaries, Write Script, the Demo planner).
        switch SystemLanguageModel.default.availability {
        case .available: checks.append(DoctorCheck("Apple Intelligence", .ok, "ready"))
        case .unavailable(.appleIntelligenceNotEnabled):
            checks.append(
                DoctorCheck(
                    "Apple Intelligence", .note, "off: no AI titles, summaries or Write Script",
                    fix: "Turn it on in System Settings › Apple Intelligence & Siri (free, on this Mac)."))
        case .unavailable(.modelNotReady):
            checks.append(DoctorCheck("Apple Intelligence", .note, "on, its model is still downloading"))
        case .unavailable(.deviceNotEligible):
            checks.append(DoctorCheck("Apple Intelligence", .note, "not supported on this Mac (AI features stay off)"))
        case .unavailable:
            checks.append(DoctorCheck("Apple Intelligence", .note, "unavailable"))
        }
        if let license {
            checks.append(
                DoctorCheck("Takely Pro", license.status, license.text, fix: "Settings › License: enter a key or buy Takely Pro."))
        }
        return checks
    }
}
