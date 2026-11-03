import AppKit
import SwiftUI
import QuartzCore

/// AppKit owns trackpad pan, momentum and pinch magnification. Both images share
/// one document coordinate system; comparison never modifies the source pixels.
struct NativeImageCanvas: NSViewRepresentable {
    let result: NSImage
    let original: NSImage?
    let comparing: Bool
    let identity: UUID?
    let actualSize: Bool
    let imagePixelWidth: Int
    let reduceMotion: Bool
    let onToggleActualSize: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CanvasScrollView {
        let scroll = CanvasScrollView(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .automatic
        scroll.verticalScrollElasticity = .automatic
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.5
        scroll.maxMagnification = 32
        scroll.contentView = CenteringCanvasClipView()
        scroll.contentView.drawsBackground = false
        let document = ComparisonDocumentView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        document.onDoubleClick = { [weak coordinator = context.coordinator] in
            coordinator?.onToggleActualSize?()
        }
        scroll.documentView = document
        document.wantsLayer = true
        context.coordinator.scroll = scroll
        context.coordinator.document = document
        scroll.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layout() }
        return scroll
    }

    func updateNSView(_ scroll: CanvasScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onToggleActualSize = onToggleActualSize
        coordinator.reduceMotion = reduceMotion
        coordinator.actualPixels = max(1, imagePixelWidth)
        if let document = coordinator.document {
            let shouldCompare = comparing && original != nil
            let imageChanged = document.result !== result
            let originalChanged = document.original !== original
            if imageChanged || originalChanged || document.comparing != shouldCompare {
                if imageChanged, !reduceMotion, document.result != nil {
                    let transition = CATransition()
                    transition.type = .fade
                    transition.duration = 0.18
                    transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    document.layer?.add(transition, forKey: "preview-transition")
                    let settle = CABasicAnimation(keyPath: "transform.scale")
                    settle.fromValue = 0.989
                    settle.toValue = 1.0
                    settle.duration = 0.25
                    settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    document.layer?.add(settle, forKey: "preview-settle")
                }
                document.result = result
                document.original = original
                document.comparing = shouldCompare
                document.needsDisplay = true
            }
            document.reducedMotion = reduceMotion
        }
        if coordinator.identity != identity {
            coordinator.identity = identity
            coordinator.lastActual = false
            coordinator.resetOnNextLayout = true
        }
        coordinator.requestedActual = actualSize
        coordinator.layout()
    }

    final class Coordinator {
        weak var scroll: CanvasScrollView?
        weak var document: ComparisonDocumentView?
        var identity: UUID?
        var onToggleActualSize: (() -> Void)?
        var requestedActual = false
        var lastActual = false
        var actualPixels = 1
        var reduceMotion = false
        var resetOnNextLayout = true
        private var lastViewport = CGSize.zero
        private var lastImageSize = CGSize.zero

        func layout() {
            guard let scroll, let document, let image = document.result else { return }
            let viewport = scroll.bounds.size
            guard viewport.width >= 1, viewport.height >= 1 else { return }
            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else { return }
            let frameChanged = viewport != lastViewport || imageSize != lastImageSize
            if frameChanged {
                let fitted = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
                let width = max(1, floor(imageSize.width * fitted))
                let height = max(1, floor(imageSize.height * fitted))
                // Update the cached geometry first: changing the document size
                // may synchronously invoke a nested NSScrollView layout.
                lastViewport = viewport
                lastImageSize = imageSize
                if document.frame.size != CGSize(width: width, height: height) {
                    document.setFrameSize(CGSize(width: width, height: height))
                }
                scroll.contentView.needsDisplay = true
            }
            if resetOnNextLayout {
                resetOnNextLayout = false
                scroll.magnification = 1
                lastActual = false
            }
            if requestedActual != lastActual || (frameChanged && requestedActual) {
                lastActual = requestedActual
                let backing = scroll.window?.backingScaleFactor ?? 2
                let desired = requestedActual
                    ? CGFloat(actualPixels) / max(1, document.frame.width * backing)
                    : 1
                let target = min(scroll.maxMagnification, max(scroll.minMagnification, desired))
                let center = NSPoint(x: document.bounds.midX, y: document.bounds.midY)
                scroll.setMagnification(target, centeredAt: center)
            }
            document.zoom = scroll.magnification
        }
    }
}

final class CanvasScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        // The comparison grip and line stay a fixed on-screen size even while
        // the user is actively pinching, rather than after SwiftUI updates.
        (documentView as? ComparisonDocumentView)?.zoom = magnification
    }
}

final class CenteringCanvasClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let document = documentView {
            if document.frame.width < proposedBounds.width {
                rect.origin.x = -(proposedBounds.width - document.frame.width) / 2
            }
            if document.frame.height < proposedBounds.height {
                rect.origin.y = -(proposedBounds.height - document.frame.height) / 2
            }
        }
        return rect
    }
}

/// Renders each image once into composited Core Animation layers. Dragging
/// and clicking the divider changes only its mask and lightweight vector
/// overlays; the source/result images are never recomputed or CPU-redrawn for
/// each pointer event.
final class ComparisonDocumentView: NSView {
    var result: NSImage? { didSet { updateImageContents() } }
    var original: NSImage? { didSet { updateImageContents() } }
    var comparing = false { didSet { updateGeometry() } }
    var reducedMotion = false
    var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { updateGeometry() } }
    }
    var onDoubleClick: (() -> Void)?
    private var draggingDivider = false
    private var installed = false
    private var cursorArea: NSTrackingArea?
    private let resultImage = CALayer()
    private let originalImage = CALayer()
    private let originalClip = CAShapeLayer()
    private let dividerLine = CALayer()
    private let grip = CALayer()
    private let gripMarks = CAShapeLayer()

    @objc dynamic var divider: CGFloat = 0.5 {
        didSet { updateGeometry() }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == "divider" { return CABasicAnimation() }
        return super.defaultAnimation(forKey: key)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installLayersIfNeeded()
    }

    override func layout() {
        super.layout()
        installLayersIfNeeded()
        updateGeometry()
    }

    private func installLayersIfNeeded() {
        guard !installed, let root = layer else { return }
        installed = true
        root.masksToBounds = true
        resultImage.contentsGravity = .resize
        originalImage.contentsGravity = .resize
        originalImage.mask = originalClip
        root.addSublayer(resultImage)
        root.addSublayer(originalImage)

        dividerLine.backgroundColor = NSColor.white.withAlphaComponent(0.93).cgColor
        dividerLine.shadowColor = NSColor.black.cgColor
        dividerLine.shadowOpacity = 0.22
        dividerLine.shadowRadius = 2
        root.addSublayer(dividerLine)

        grip.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        grip.borderColor = NSColor.separatorColor.cgColor
        grip.borderWidth = 0.8
        grip.shadowColor = NSColor.black.cgColor
        grip.shadowOpacity = 0.14
        grip.shadowRadius = 4
        grip.shadowOffset = CGSize(width: 0, height: 1)
        gripMarks.fillColor = nil
        gripMarks.strokeColor = NSColor.secondaryLabelColor.cgColor
        gripMarks.lineCap = .round
        grip.addSublayer(gripMarks)
        root.addSublayer(grip)

        updateImageContents()
        updateGeometry()
    }

    private func updateImageContents() {
        guard installed else { return }
        // NSImage was initialized with CGImage on the preview-loader actor;
        // retaining the CGImage as layer contents avoids expensive redraws.
        resultImage.contents = result?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        originalImage.contents = original?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        updateGeometry()
    }

    private func updateGeometry() {
        guard installed else { return }
        CATransaction.begin()
        // Direct drag must never inherit implicit CA easing or introduce latency.
        CATransaction.setDisableActions(true)
        resultImage.frame = bounds
        originalImage.frame = bounds
        originalClip.frame = originalImage.bounds
        let position = bounds.width * min(1, max(0, divider))
        originalClip.path = CGPath(rect: CGRect(x: 0, y: 0,
                                               width: position, height: bounds.height),
                                   transform: nil)
        let factor = max(0.5, zoom)
        let lineWidth = 1.8 / factor
        dividerLine.frame = CGRect(x: position - lineWidth / 2, y: 0,
                                   width: lineWidth, height: bounds.height)
        let radius = 13 / factor
        grip.frame = CGRect(x: position - radius, y: bounds.midY - radius,
                            width: radius * 2, height: radius * 2)
        grip.cornerRadius = radius
        gripMarks.frame = grip.bounds
        gripMarks.lineWidth = 1 / factor
        let ticks = CGMutablePath()
        ticks.move(to: CGPoint(x: radius - 7 / factor, y: radius))
        ticks.addLine(to: CGPoint(x: radius - 3 / factor, y: radius))
        ticks.move(to: CGPoint(x: radius + 3 / factor, y: radius))
        ticks.addLine(to: CGPoint(x: radius + 7 / factor, y: radius))
        gripMarks.path = ticks

        let showDivider = comparing && original != nil && result != nil
        originalImage.isHidden = !showDivider
        dividerLine.isHidden = !showDivider
        grip.isHidden = !showDivider
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorArea { removeTrackingArea(cursorArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorArea = area
    }

    override func mouseDown(with event: NSEvent) {
        guard result != nil else { return }
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        guard comparing, original != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let distance = abs(point.x - bounds.width * divider)
        if distance <= 18 / max(0.5, zoom) {
            draggingDivider = true
        } else {
            let destination = min(1, max(0, point.x / max(1, bounds.width)))
            if reducedMotion {
                divider = destination
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.13
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    animator().divider = destination
                }
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingDivider else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Pointer motion always wins over an interrupted click-to-move animation.
        layer?.removeAllAnimations()
        divider = min(1, max(0, point.x / max(1, bounds.width)))
    }

    override func mouseUp(with event: NSEvent) {
        draggingDivider = false
    }

    override func keyDown(with event: NSEvent) {
        guard comparing else { super.keyDown(with: event); return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 0.1 : 0.025
        switch event.keyCode {
        case 123: divider = max(0, divider - step)
        case 124: divider = min(1, divider + step)
        default: super.keyDown(with: event)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard comparing else { NSCursor.arrow.set(); return }
        let point = convert(event.locationInWindow, from: nil)
        if abs(point.x - bounds.width * divider) < 18 / max(0.5, zoom) {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
