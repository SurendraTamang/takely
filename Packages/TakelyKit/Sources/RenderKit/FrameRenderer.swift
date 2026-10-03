import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ProjectKit

/// Composes one output frame: screen (blurs → cursor halo → click pulses, then zoomed) → camera bubble → captions.
/// Times are on the recording timeline (the compositor maps cut exports back to it).
///
/// Immutable after init, so safe to share across concurrent compositor requests.
public final class FrameRenderer: Sendable {
    public let context: CIContext
    private let project: Project
    private let cursor: CursorTrack
    private let canvas: CGRect

    /// Caption images rendered once up front (one per cue), drawn while their cue is on.
    private let captions: [(cue: CaptionCue, image: CIImage)]
    /// Areas blurred out (secrets on screen, areas the user chose); only enabled ones are kept.
    private let redactions: [Redaction]
    private let zooms: [Zoom]
    /// A talking portrait in the bubble instead of the camera (Demo Mode narration).
    private let avatar: (image: CIImage, face: AvatarFace, voice: VoiceLevels)?
    /// The cursor, smoothed, sampled every `1 / pathRate` s (for zooms that follow it). Precomputed: frames are
    /// rendered concurrently and out of order, so each must depend only on its time.
    private let cursorPath: [NormalizedPoint]
    static let pathRate = 30.0
    /// The smoothed cursor catches up with the real one over about this long.
    static let followLag = 0.35

    public init(
        project: Project, cursor: CursorTrack, captions: [CaptionCue] = [], redactions: [Redaction] = [], zooms: [Zoom] = [],
        avatar: (image: CIImage, face: AvatarFace, voice: VoiceLevels)? = nil,
        context: CIContext = CIContext(options: [.cacheIntermediates: false])
    ) {
        self.project = project
        self.cursor = cursor
        self.context = context
        let canvas = CGRect(x: 0, y: 0, width: project.capture.pixelSize.width, height: project.capture.pixelSize.height)
        self.canvas = canvas
        self.captions = project.effects.burnInCaptions == true ? captions.map { ($0, Self.captionImage($0.text, canvas: canvas)) } : []
        self.redactions = redactions.filter(\.enabled)
        self.zooms = zooms.filter { $0.end > $0.start && $0.scale > 1 }
        self.avatar = avatar
        cursorPath = self.zooms.contains { $0.focus == .cursor } ? Self.smoothedPath(cursor, duration: project.duration) : []
    }

    /// Whether the avatar will be drawn (the export then needs the compositor).
    public var hasAvatar: Bool { avatar != nil }
    var avatarVoice: VoiceLevels? { avatar?.voice }

    /// Whether any zoom will be drawn (the export then needs the compositor).
    public var hasZooms: Bool { !zooms.isEmpty }

    /// Exponential smoothing of the cursor (a critically damped follow): the zoom glides instead of jittering.
    static func smoothedPath(_ cursor: CursorTrack, duration: Double) -> [NormalizedPoint] {
        let step = 1 / pathRate
        let pull = 1 - exp(-step / followLag)
        var path: [NormalizedPoint] = []
        var current: NormalizedPoint?
        for i in 0...Int(duration * pathRate) {
            let target = cursor.position(at: Double(i) * step) ?? current ?? NormalizedPoint(x: 0.5, y: 0.5)
            let p = current.map { NormalizedPoint(x: $0.x + (target.x - $0.x) * pull, y: $0.y + (target.y - $0.y) * pull) } ?? target
            path.append(p)
            current = p
        }
        return path
    }

    /// Whether anything will be blurred (the export then needs the compositor).
    public var hasRedactions: Bool { !redactions.isEmpty }

    /// Whether any burned-in caption will be drawn (the export then needs the compositor).
    public var hasCaptions: Bool { !captions.isEmpty }

    /// White text on a translucent dark box, centred near the bottom (sized to the frame height).
    private static func captionImage(_ text: String, canvas: CGRect) -> CIImage {
        // Sized by height, but small enough that a 42-character line fits narrow (square, portrait) captures too.
        let size = max(12, min(canvas.height * 0.045, canvas.width * 0.04))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let generator = CIFilter.attributedTextImageGenerator()
        generator.text = NSAttributedString(
            string: text,
            attributes: [
                .font: CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil), .foregroundColor: CGColor(gray: 1, alpha: 1),
                .paragraphStyle: style,
            ])
        generator.scaleFactor = 1
        guard let textImage = generator.outputImage else { return CIImage.empty() }
        let pad = size * 0.4
        let box = textImage.extent.insetBy(dx: -pad, dy: -pad * 0.6)
        let backing = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.65)).cropped(to: box)
        let caption = textImage.composited(over: backing)
        let x = canvas.midX - box.width / 2 - box.minX
        let y = canvas.height * 0.06 - box.minY
        return caption.transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    /// `t` is recording time; `outputTime` (where this frame is in the export, after cuts) times the avatar's
    /// mouth to the narration as it plays.
    public func compose(screen: CIImage, camera: CIImage?, at t: Double, outputTime: Double? = nil) -> CIImage {
        var image = redact(screen, at: t)
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
        image = zoom(image.cropped(to: canvas), at: t)
        if project.camera.enabled, let camera, let center = project.camera.bubbleCenter(at: t) {
            image = bubble(camera, center: point(center)).composited(over: image)
        } else if let avatar, let center = project.camera.bubbleCenter(at: t) {
            image = bubble(avatarFrame(avatar, at: t, voiceAt: outputTime ?? t), center: point(center)).composited(over: image)
        }
        if let caption = captions.first(where: { $0.cue.start <= t && t < $0.cue.end }) {
            image = caption.image.composited(over: image)
        }
        return image.cropped(to: canvas)
    }

    /// The portrait at `t`: mouth opened by the narration's loudness, eyelids closed while blinking, a gentle bob.
    func avatarFrame(_ avatar: (image: CIImage, face: AvatarFace, voice: VoiceLevels), at t: Double, voiceAt: Double? = nil) -> CIImage {
        let extent = avatar.image.extent
        let (w, h) = (extent.width, extent.height)
        let face = avatar.face
        /// A soft-edged filled ellipse in image coordinates (origin bottom-left).
        func ellipse(around r: NormalizedRect, width: Double, height: Double, color: CIColor) -> CIImage {
            guard width > 0.5, height > 0.5 else { return .empty() }
            let gradient = CIFilter.radialGradient()
            gradient.center = .zero
            gradient.radius0 = 80
            gradient.radius1 = 100
            gradient.color0 = color
            gradient.color1 = CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0)
            let center = CGPoint(x: extent.minX + (r.x + r.width / 2) * w, y: extent.minY + (1 - r.y - r.height / 2) * h)
            return gradient.outputImage!.cropped(to: CGRect(x: -100, y: -100, width: 200, height: 200))
                .transformed(by: CGAffineTransform(scaleX: width / 200, y: height / 200))
                .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
        }
        var image = avatar.image
        let level = avatar.voice.level(at: voiceAt ?? t)
        let mouth = face.mouth
        image = ellipse(
            around: mouth, width: mouth.width * w * 0.8, height: mouth.height * h * 1.4 * level,
            color: CIColor(red: 0.09, green: 0.04, blue: 0.04)  // a mouth's dark inside, not a colour of its own
        ).composited(over: image)
        let closed = AvatarMotion.blink(at: t)
        if closed > 0.05 {
            // An eyelid is the skin above the eye, a little shaded.
            let skin = CIColor(
                red: (face.skin[safe: 0] ?? 0.85) * 0.9, green: (face.skin[safe: 1] ?? 0.7) * 0.9, blue: (face.skin[safe: 2] ?? 0.6) * 0.9)
            for eye in [face.leftEye, face.rightEye] {
                image = ellipse(around: eye, width: eye.width * w * 1.4, height: eye.height * h * 1.8 * closed, color: skin)
                    .composited(over: image)
            }
        }
        let rise = AvatarMotion.bob(at: t, level: level) * h
        return image.clampedToExtent().transformed(by: CGAffineTransform(translationX: 0, y: rise)).cropped(to: extent)
    }

    /// Scales the screen around the zoom's focus, keeping the view inside the screen.
    private func zoom(_ image: CIImage, at t: Double) -> CIImage {
        guard let zoom = zooms.first(where: { $0.start < t && t < $0.end }) else { return image }
        let s = zoom.scale(at: t)
        guard s > 1.0001 else { return image }
        let focus: NormalizedPoint
        switch zoom.focus {
        case .cursor:
            focus =
                cursorPath.isEmpty
                ? NormalizedPoint(x: 0.5, y: 0.5) : cursorPath[min(cursorPath.count - 1, max(0, Int((t * Self.pathRate).rounded())))]
        case .point(let p):
            focus = p
        }
        let c = point(focus)
        let view = CGSize(width: canvas.width / s, height: canvas.height / s)
        let x = min(max(c.x - view.width / 2, 0), canvas.width - view.width)
        let y = min(max(c.y - view.height / 2, 0), canvas.height - view.height)
        return image.transformed(by: CGAffineTransform(translationX: -x, y: -y).concatenating(CGAffineTransform(scaleX: s, y: s)))
            .cropped(to: canvas)
    }

    /// Pixellates, then blurs, each active redaction's box (padded a little): unrecoverable, unlike a light blur.
    private func redact(_ screen: CIImage, at t: Double) -> CIImage {
        var image = screen
        for redaction in redactions {
            guard let r = redaction.rect(at: t) else { continue }
            let pad = r.height * canvas.height * 0.15 + 2
            let box = CGRect(
                x: r.x * canvas.width - pad, y: (1 - r.y - r.height) * canvas.height - pad, width: r.width * canvas.width + 2 * pad,
                height: r.height * canvas.height + 2 * pad
            ).intersection(canvas)
            guard !box.isNull, box.width > 0, box.height > 0 else { continue }
            let cell = max(8, box.height / 3)
            let covered = image.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: cell, kCIInputCenterKey: CIVector(x: box.minX, y: box.minY)])
                .applyingGaussianBlur(sigma: cell / 2)
                .cropped(to: box)
            image = covered.composited(over: image)
        }
        return image
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

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
