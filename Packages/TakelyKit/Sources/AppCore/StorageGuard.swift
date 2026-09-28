import Foundation

/// Disk-space rules that keep a recording, and its export, from running the disk out.
public enum StorageGuard {
    /// Refuse to start below this.
    public static let minimumFreeToStart: Int64 = 2_000_000_000
    /// Always leave this much free, on top of room for the export.
    public static let reserve: Int64 = 500_000_000

    public static func canStart(freeBytes: Int64) -> Bool {
        freeBytes >= minimumFreeToStart
    }

    /// The export writes a file about as large as the recording, so keep that much free plus the reserve.
    public static func mustStop(freeBytes: Int64, recordedBytes: Int64) -> Bool {
        freeBytes < reserve + recordedBytes
    }
}

/// Free and used space, behind a protocol so tests can fake a nearly full disk.
public protocol DiskSpace: Sendable {
    func freeBytes(at url: URL) throws -> Int64
    /// Total size of the files under `url`.
    func usedBytes(at url: URL) -> Int64
}

public struct SystemDiskSpace: DiskSpace {
    public init() {}

    /// Counts purgeable space macOS frees on demand, so recordings don't stop early.
    public func freeBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    public func usedBytes(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
