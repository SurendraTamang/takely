import CoreGraphics
import ProjectKit

/// Region geometry for ScreenCaptureKit. Regions and display frames are global points, origin top-left
/// (`CGDisplayBounds`); a stream's `sourceRect` is local to its display.
public enum CaptureGeometry {
    /// Smallest region, in points, on either side.
    public static let minimumSize = 64.0

    /// The region (in any drag direction) snapped to whole points and clamped to `display`; nil if what's left is
    /// smaller than `minimumSize`.
    public static func clamp(_ region: CGRect, to display: CGRect) -> CGRect? {
        let r = region.standardized
        let snapped = CGRect(
            x: r.minX.rounded(), y: r.minY.rounded(), width: r.maxX.rounded() - r.minX.rounded(),
            height: r.maxY.rounded() - r.minY.rounded())
        let clamped = snapped.intersection(display)
        guard !clamped.isNull, clamped.width >= minimumSize, clamped.height >= minimumSize else { return nil }
        return clamped
    }

    /// `SCStreamConfiguration.sourceRect` for a region on `display`.
    public static func sourceRect(for region: CGRect, on display: CGRect) -> CGRect {
        region.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    /// Pixel size of a rect at `scale` pixels per point, rounded down to even (encoder requirement).
    public static func pixelSize(of rect: CGRect, scale: Double) -> PixelSize {
        PixelSize(width: Int(rect.width * scale).even, height: Int(rect.height * scale).even)
    }
}
