import CoreMedia

extension CMSampleBuffer {
    /// Copy of a single-timing sample buffer with a new presentation time.
    func retimed(to pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: self,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }
}
