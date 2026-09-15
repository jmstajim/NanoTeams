import SwiftUI

// MARK: - NTMSLoaderLayerView

/// Plays `NTMSLoader`'s frame sequence on Core Animation, so a live spinner costs the main
/// thread nothing between setup and teardown.
///
/// Every frame is a pre-rendered glyph image. Discrete `CAKeyframeAnimation`s switch them —
/// `contents` on the glyph and on the two RGB-split copies, `opacity` on the copies,
/// `transform` on the jitter layer — each with `repeatCount = .infinity`. The render server
/// steps them; SwiftUI sees one view whose inputs do not change, so a spinner no longer
/// schedules a transaction on the window 12.5 times a second (see `NTMSLoaderAnimationScript`
/// for the measurement).
///
/// **Parity with the SwiftUI `Text` it replaced.** Glyph images come from `ImageRenderer`
/// over the same `Text(glyph).font(font).foregroundStyle(color)`, so face fallback, metrics
/// and antialiasing are SwiftUI's own. The color is resolved against THIS view's environment
/// in `updateNSView`: `ImageRenderer` has no window, and a dynamic `Colors.*` token resolved
/// without one follows whatever appearance happens to be current. The resolved value is part
/// of `Inputs`, so a theme or light/dark switch re-renders. Images sit with
/// `contentsGravity = .center` in unclipped layers, so a glitch glyph wider than the cell
/// spills into the gutter exactly as the overlaid `Text` did.
struct NTMSLoaderLayerView: NSViewRepresentable {
    let font: Font
    let color: Color
    let glitchEnabled: Bool

    func makeNSView(context: Context) -> NTMSLoaderLayerNSView {
        NTMSLoaderLayerNSView(frame: .zero)
    }

    func updateNSView(_ nsView: NTMSLoaderLayerNSView, context: Context) {
        nsView.update(NTMSLoaderLayerNSView.Inputs(
            font: font,
            color: color.resolve(in: context.environment),
            glitchEnabled: glitchEnabled
        ))
    }

    /// An explicit proposal is the sized footprint's frame. `MonoCell`'s `.fixedSize()`
    /// proposes nothing, and then the view is its resting glyph — the same box the overlaid
    /// `Text` had, which `MonoCell` centres over its reference glyph.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NTMSLoaderLayerNSView,
        context: Context
    ) -> CGSize? {
        if let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite {
            return CGSize(width: width, height: height)
        }
        return nsView.restingGlyphSize
    }
}

// MARK: - NTMSLoaderLayerNSView

/// The layer stack behind `NTMSLoaderLayerView`: a jitter layer holding the red copy, the
/// cyan copy and the glyph, in the z-order the SwiftUI `ZStack` drew them.
final class NTMSLoaderLayerNSView: NSView {

    /// Everything the rendered images and the script depend on, besides the backing scale.
    struct Inputs: Equatable {
        let font: Font
        let color: Color.Resolved
        let glitchEnabled: Bool
    }

    // RGB-split channels for the chromatic-aberration overlay. NOT design-system
    // colors — the glitch effect demands the canonical full-saturation R / C
    // channels; muting them with `Colors.error` etc. kills the look. Cyan has
    // no semantic token equivalent either. Scoped to this file by design.
    private static let glitchChannelRed = Color(red: 1.0, green: 0.0, blue: 0.0)
    private static let glitchChannelCyan = Color(red: 0.0, green: 1.0, blue: 1.0)

    static let contentsAnimationKey = "ntms.loader.contents"
    static let opacityAnimationKey = "ntms.loader.opacity"
    static let shakeAnimationKey = "ntms.loader.shake"

    let shakeLayer = NTMSLoaderLayerNSView.silentLayer()
    let redLayer = NTMSLoaderLayerNSView.silentLayer()
    let cyanLayer = NTMSLoaderLayerNSView.silentLayer()
    let glyphLayer = NTMSLoaderLayerNSView.silentLayer()

    private(set) var inputs: Inputs?
    /// The resting rotation glyph's size in points — the view's natural size.
    private(set) var restingGlyphSize: CGSize?
    private var renderedScale: CGFloat = 0
    private var installed: [(layer: CALayer, key: String, animation: CAAnimation)] = []

    #if DEBUG
    private(set) var renderPassCountForTesting = 0
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        shakeLayer.addSublayer(redLayer)
        shakeLayer.addSublayer(cyanLayer)
        shakeLayer.addSublayer(glyphLayer)
        layer?.addSublayer(shakeLayer)
        redLayer.opacity = 0
        cyanLayer.opacity = 0
        layoutGlyphLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Decoration: clicks, hover and tooltips belong to the row the spinner sits in.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }

    override var intrinsicContentSize: NSSize {
        restingGlyphSize ?? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutGlyphLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildIfScaleChanged()
    }

    /// Animations normally survive a window change; this re-adds them if the layer tree was
    /// rebuilt underneath, and re-renders if the new window has a different backing scale.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, inputs != nil else { return }
        if !rebuildIfScaleChanged(), glyphLayer.animation(forKey: Self.contentsAnimationKey) == nil {
            installAnimations()
        }
    }

    /// Re-renders only when the inputs or the backing scale actually changed. SwiftUI calls
    /// `updateNSView` on every parent pass; a pass that changes nothing must stay free.
    func update(_ newInputs: Inputs) {
        guard newInputs != inputs else {
            rebuildIfScaleChanged()
            return
        }
        inputs = newInputs
        rebuild(scale: currentScale)
    }

    // MARK: - Private

    private var currentScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    @discardableResult
    private func rebuildIfScaleChanged() -> Bool {
        let scale = currentScale
        guard inputs != nil, scale != renderedScale else { return false }
        rebuild(scale: scale)
        return true
    }

    private func layoutGlyphLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shakeLayer.frame = bounds
        glyphLayer.frame = shakeLayer.bounds
        redLayer.frame = shakeLayer.bounds.offsetBy(dx: 1, dy: 0)
        cyanLayer.frame = shakeLayer.bounds.offsetBy(dx: -1, dy: 0)
        CATransaction.commit()
    }

    private func rebuild(scale: CGFloat) {
        guard let inputs else { return }
        renderedScale = scale
        #if DEBUG
        renderPassCountForTesting &+= 1
        #endif

        var generator = SystemRandomNumberGenerator()
        let frames = NTMSLoaderAnimationScript.make(
            NTMSLoaderAnimationScript.Parameters(
                rotationCount: NTMSLoader.rotationFrames.count,
                glitchEnabled: inputs.glitchEnabled,
                probability: NTMSLoaderAnimationScript.glitchTriggerProbability,
                burstRange: NTMSLoaderAnimationScript.glitchFrameRange,
                glitchGlyphs: NTMSLoader.glitchGlyphs
            ),
            minimumTicks: NTMSLoaderAnimationScript.minimumCycleTicks,
            using: &generator
        )

        var images = GlyphImages(font: inputs.font, main: Color(inputs.color), scale: scale)
        let restingGlyph = NTMSLoader.rotationFrames[0]
        guard let restingImage = images.image(restingGlyph, .main) else {
            installed = []
            installAnimations()
            return
        }

        let glitches = frames.contains { $0.glitchGlyph != nil }
        var contents: [Any] = []
        var redContents: [Any] = []
        var cyanContents: [Any] = []
        var opacity: [Any] = []
        var shake: [Any] = []
        for frame in frames {
            let glyph = frame.glitchGlyph ?? NTMSLoader.rotationFrames[frame.rotationIndex]
            contents.append(images.image(glyph, .main) ?? restingImage)
            guard glitches else { continue }
            // Outside a burst the copies are transparent, so any image will do — the resting
            // glyph's avoids rendering one per rotation angle.
            let copy = frame.glitchGlyph ?? restingGlyph
            redContents.append(images.image(copy, .red) ?? restingImage)
            cyanContents.append(images.image(copy, .cyan) ?? restingImage)
            opacity.append(NSNumber(value: frame.glitchGlyph == nil ? 0 : 1))
            shake.append(NSValue(caTransform3D: CATransform3DMakeTranslation(frame.shake.width, frame.shake.height, 0)))
        }

        let keyTimes = NTMSLoaderAnimationScript.keyTimes(frameCount: frames.count).map { NSNumber(value: $0) }
        let duration = Double(frames.count) * NTMSLoaderAnimationScript.tickSeconds
        func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = keyTimes
            animation.calculationMode = .discrete
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            return animation
        }

        installed = [(glyphLayer, Self.contentsAnimationKey, keyframes("contents", contents))]
        if glitches {
            let fade = keyframes("opacity", opacity)
            installed += [
                (redLayer, Self.contentsAnimationKey, keyframes("contents", redContents)),
                (redLayer, Self.opacityAnimationKey, fade),
                (cyanLayer, Self.contentsAnimationKey, keyframes("contents", cyanContents)),
                (cyanLayer, Self.opacityAnimationKey, fade),
                (shakeLayer, Self.shakeAnimationKey, keyframes("transform", shake)),
            ]
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [glyphLayer, redLayer, cyanLayer] {
            layer.contentsScale = scale
        }
        // Model values: what shows if the animations are ever gone — the steady resting glyph.
        glyphLayer.contents = restingImage
        redLayer.contents = nil
        cyanLayer.contents = nil
        CATransaction.commit()

        let size = CGSize(width: CGFloat(restingImage.width) / scale, height: CGFloat(restingImage.height) / scale)
        if size != restingGlyphSize {
            restingGlyphSize = size
            invalidateIntrinsicContentSize()
        }
        installAnimations()
    }

    /// Replaces every animation in one transaction, so all layers share a begin time and the
    /// glyph and its copies never step out of phase.
    private func installAnimations() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [shakeLayer, redLayer, cyanLayer, glyphLayer] {
            layer.removeAllAnimations()
        }
        for entry in installed {
            entry.layer.add(entry.animation, forKey: entry.key)
        }
        CATransaction.commit()
    }

    /// A layer with no implicit animations: every visible change here is either a keyframe
    /// animation or a model value that must land without a fade.
    nonisolated private static func silentLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .center
        layer.masksToBounds = false
        layer.actions = [
            "contents": NSNull(), "opacity": NSNull(), "transform": NSNull(),
            "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull(),
        ]
        return layer
    }

    private enum Channel {
        case main, red, cyan
    }

    /// Renders each (glyph, channel) once per rebuild.
    private struct GlyphImages {
        let font: Font
        let main: Color
        let scale: CGFloat
        private var cache: [String: CGImage] = [:]

        init(font: Font, main: Color, scale: CGFloat) {
            self.font = font
            self.main = main
            self.scale = scale
        }

        mutating func image(_ glyph: String, _ channel: Channel) -> CGImage? {
            let key = "\(channel)|\(glyph)"
            if let cached = cache[key] { return cached }
            let color: Color = switch channel {
            case .main: main
            case .red: NTMSLoaderLayerNSView.glitchChannelRed
            case .cyan: NTMSLoaderLayerNSView.glitchChannelCyan
            }
            let renderer = ImageRenderer(content: Text(glyph).font(font).foregroundStyle(color))
            renderer.scale = scale
            let image = renderer.cgImage
            cache[key] = image
            return image
        }
    }
}
