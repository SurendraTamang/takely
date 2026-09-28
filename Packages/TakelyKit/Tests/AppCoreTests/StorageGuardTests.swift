import Foundation
import TestSupport
import Testing

@testable import AppCore

@Suite struct StorageGuardTests {
    @Test func needsTwoGigabytesToStart() {
        #expect(!StorageGuard.canStart(freeBytes: 1_999_999_999))
        #expect(StorageGuard.canStart(freeBytes: 2_000_000_000))
    }

    @Test func reservesRoomForTheExport() {
        // 3 GB recorded needs 3.5 GB free to keep going.
        #expect(!StorageGuard.mustStop(freeBytes: 3_600_000_000, recordedBytes: 3_000_000_000))
        #expect(!StorageGuard.mustStop(freeBytes: 3_500_000_000, recordedBytes: 3_000_000_000))  // exactly enough
        #expect(StorageGuard.mustStop(freeBytes: 3_400_000_000, recordedBytes: 3_000_000_000))
        #expect(StorageGuard.mustStop(freeBytes: 400_000_000, recordedBytes: 0))
    }

    @Test func systemDiskSpaceReadsRealValues() throws {
        let folder = Synthetic.temporaryFolder()
        try Data(count: 10_000).write(to: folder.appending(path: "file.bin"))
        let disk = SystemDiskSpace()
        #expect(try disk.freeBytes(at: folder) > 0)
        #expect(disk.usedBytes(at: folder) >= 10_000)
    }

    @Test func freeSpaceIsReadFreshEachTime() throws {
        let folder = Synthetic.temporaryFolder()
        let disk = SystemDiskSpace()
        let before = try disk.freeBytes(at: folder)  // same URL value both times, as the controller does
        let file = folder.appending(path: "big.bin")
        try Data(count: 200_000_000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let after = try disk.freeBytes(at: folder)
        #expect(before - after > 100_000_000, "before \(before) after \(after)")
    }

    @Test func fallsBackWhenImportantUsageIsZeroOrMissing() {
        #expect(SystemDiskSpace.bestAvailable(importantUsage: 0, plain: 209_354_752) == 209_354_752)  // exFAT
        #expect(SystemDiskSpace.bestAvailable(importantUsage: nil, plain: 5) == 5)
        #expect(SystemDiskSpace.bestAvailable(importantUsage: 10, plain: 5) == 10)
        #expect(SystemDiskSpace.bestAvailable(importantUsage: nil, plain: nil) == 0)
    }
}
