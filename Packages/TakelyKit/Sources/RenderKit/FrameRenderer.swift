import CoreImage
import CoreImage.CIFilterBuiltins
import ProjectKit

/// Composes one output frame: screen → cursor halo → click pulses → camera bubble.
///
/// Immutable after init, so safe to share across concurrent compositor requests.
public final class FrameRenderer: Sendable {
    public let context: CIContext
    private let project: Project
    private let cursor: CursorTrack
    private let canvas: CGRect

    public init(project: Project, cursor: CursorTrack, context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.project = project
        self.cursor = cursor
        self.context = context
        canvas = CGRect(x: 0, y: 0, width: project.capture.pixelSize.width, height: project.capture.pixelSize.height)
    }

    /// `true` when output differs from the raw screen track.
    public var hasOverlays: Bool {
        project.camera.enabled || project.effects.cursorHighlight || project.effects.clickRipples
    }

    public func compose(screen: CIImage, camera: CIImage?, at t: Double) -> CIImage {
        var image = screen
        if project.effects.cursorHighlight, let p = cursor.position(at: t) {
            let r = canvas.height * 0.035
            image = glow(at: point(p), radius: r, color: CIColor(red: 1, green: 0.85, blue: 0, alpha: 0.35))
                .composited(over: image)
        }
        if project.effects.clickRipples {
            for active in cursor.clicks(activeAt: t) {
                let r = canvas.height * 0.05 * (0.3 + 0.7 * active.progress)
                let alpha = 0.5 * (1 - active.progress)
                image = glow(
                    at: point(NormalizedPoint(x: active.click.x, y: active.click.y)), radius: r,
                    color: CIColor(red: 1, green: 1, blue: 1, alpha: alpha)
                )
                .composited(over: image)
            }
        }
        if project.camera.enabled, let camera, let center = project.camera.bubbleCenter(at: t) {
            image = bubble(camera, center: point(center)).composited(over: image)
        }
        return image.cropped(to: canvas)
    }

    /// Normalized top-left coordinates → Core Image pixels (origin bottom-left).
    private func point(_ p: NormalizedPoint) -> CGPoint {
        CGPoint(x: p.x * canvas.width, y: (1 - p.y) * canvas.height)
    }

    private func glow(at center: CGPoint, radius: Double, color: CIColor) -> CIImage {
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(radius * 0.6)
        gradient.radius1 = Float(radius)
        gradient.color0 = color
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        return gradient.outputImage!.cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func bubble(_ camera: CIImage, center: CGPoint) -> CIImage {
        let d = project.camera.size * canvas.width
        let rect = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        let e = camera.extent
        let scale = d / min(e.width, e.height)
        let fitted =
            camera
            .transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
            .cropped(to: rect)

        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = rect
        mask.radius = Float(cornerRadius(diameter: d))
        mask.color = .white
        let maskImage = mask.outputImage!

        let shaped = fitted.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: maskImage,
            ])
        let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            .applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: maskImage,
                ]
            )
            .applyingGaussianBlur(sigma: d * 0.04)
            .transformed(by: CGAffineTransform(translationX: 0, y: -d * 0.02))
        return shaped.composited(over: shadow)
    }

    private func cornerRadius(diameter d: Double) -> Double {
        switch project.camera.shape {
        case .circle: d / 2
        case .rounded: d * 0.22
        case .square: 0
        }
    }
}
