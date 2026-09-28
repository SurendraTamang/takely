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
}
