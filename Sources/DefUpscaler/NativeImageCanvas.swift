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
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .automatic
        scroll.verticalScrollElasticity = .automatic
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.5
        scroll.maxMagnification = 32
        scroll.contentView = CenteringCanvasClipView()
        let document = ComparisonDocumentView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        document.onDoubleClick = { [weak coordinator = context.coordinator] in
            coordinator?.onToggleActualSize?()
        }
        scroll.documentView = document
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
        coordinator.document?.result = result
        coordinator.document?.original = original
        coordinator.document?.comparing = comparing && original != nil
        coordinator.document?.setNeedsDisplay(coordinator.document?.bounds ?? .zero)
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
                if document.frame.size != CGSize(width: width, height: height) {
                    document.setFrameSize(CGSize(width: width, height: height))
                }
                lastViewport = viewport
                lastImageSize = imageSize
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

/// Draws both versions at identical dimensions and orientation. Interactive
/// divider is 32 screen points wide, while the visible line is only 1.8 points.
final class ComparisonDocumentView: NSView {
    var result: NSImage?
    var original: NSImage?
    var comparing = false
    var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { needsDisplay = true } }
    }
    var onDoubleClick: (() -> Void)?
    private var draggingDivider = false
    @objc dynamic var divider: CGFloat = 0.5 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == "divider" { return CABasicAnimation() }
        return super.defaultAnimation(forKey: key)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.textBackgroundColor.setFill()
        NSRectFill(bounds)
        guard let result else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        result.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        guard comparing, let original else { return }
        let split = bounds.width * divider
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: split, height: bounds.height)).addClip()
        original.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let adjusted = max(0.5, zoom)
        let line = NSRect(x: split - 0.9 / adjusted, y: 0, width: 1.8 / adjusted, height: bounds.height)
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSRectFill(line)
        let radius = 15 / adjusted
        let grip = NSRect(x: split - radius, y: bounds.midY - radius,
                          width: 2 * radius, height: 2 * radius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.93).setFill()
        NSBezierPath(ovalIn: grip).fill()
        NSColor.secondaryLabelColor.setStroke()
        NSBezierPath(ovalIn: grip).stroke()
        // Short lateral ticks communicate the dragging affordance.
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: split - 7 / adjusted, y: bounds.midY))
        tick.line(to: NSPoint(x: split - 3 / adjusted, y: bounds.midY))
        tick.move(to: NSPoint(x: split + 3 / adjusted, y: bounds.midY))
        tick.line(to: NSPoint(x: split + 7 / adjusted, y: bounds.midY))
        tick.lineWidth = 1 / adjusted
        tick.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard result != nil else { return }
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        guard comparing else { return }
        let position = convert(event.locationInWindow, from: nil)
        let hitDistance = abs(position.x - bounds.width * divider)
        if hitDistance <= 18 / max(0.5, zoom) {
            draggingDivider = true
            // The next mouseDragged event writes the actual pointer location.
        } else {
            let newValue = min(1, max(0, position.x / max(1, bounds.width)))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.13
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().divider = newValue
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingDivider else { return }
        let position = convert(event.locationInWindow, from: nil)
        // Direct interaction always wins over a previous animated click.
        layer?.removeAllAnimations()
        divider = min(1, max(0, position.x / max(1, bounds.width)))
    }

    override func mouseUp(with event: NSEvent) {
        draggingDivider = false
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }
}
