import Foundation

/// One line of `takely doctor`: what was checked, how it stands, and what to do about it.
public struct DoctorCheck: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case ok
        /// Fine for what's set up now, but worth knowing (a feature that's off, a permission not asked for yet).
        case note
        /// Something Takely needs isn't there.
        case problem
    }

    public var name: String
    public var status: Status
    public var detail: String
    /// What to do, when it isn't fine.
    public var fix: String?

    public init(_ name: String, _ status: Status, _ detail: String, fix: String? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.fix = fix
    }

    /// "✓ Screen Recording: allowed", "✗ …: off\n    → fix", problems counted at the end.
    public static func report(_ checks: [DoctorCheck]) -> String {
        var lines = checks.map { check -> String in
            let mark =
                switch check.status {
                case .ok: "✓"
                case .note: "•"
                case .problem: "✗"
                }
            var line = "\(mark) \(check.name): \(check.detail)"
            if let fix = check.fix, check.status != .ok { line += "\n    → \(fix)" }
            return line
        }
        let problems = checks.filter { $0.status == .problem }.count
        lines.append(problems == 0 ? "\nAll good." : "\n\(problems) problem\(problems == 1 ? "" : "s") to fix.")
        return lines.joined(separator: "\n")
    }
}
