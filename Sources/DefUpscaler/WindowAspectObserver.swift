import AppKit
import SwiftUI
import QuartzCore

/// Adapts only until the user starts manually resizing. Never repositions a
/// fullscreen or zoomed window, nor places the window outside visible bounds.
struct WindowAspectObserver: NSViewRepresentable {
    let aspect: CGFloat?
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        let coordinator = context.coordinator
        view.onWindowChange = { [weak coordinator] window in
            coordinator?.attach(window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowProbe, context: Context) {
        context.coordinator.attach(nsView.window)
        context.coordinator.update(aspect: aspect, reduceMotion: reduceMotion)
    }

    final class WindowProbe: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?
        private var lastAspect: CGFloat?
        private var userResized = false

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func attach(_ window: NSWindow?) {
            guard let window, self.window !== window else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            self.window = window
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.userResized = true
            }
            // Window installation can occur after updateNSView; let the next
            // aspect update trigger a resize once attached.
            lastAspect = nil
        }

        func update(aspect: CGFloat?, reduceMotion: Bool) {
            guard let aspect, aspect.isFinite, aspect > 0,
                  let window, let screen = window.screen,
                  !userResized, !window.isZoomed,
                  !window.styleMask.contains(.fullScreen),
                  lastAspect == nil || abs((lastAspect ?? 0) - aspect) > 0.08 else { return }
            lastAspect = aspect
            let visible = screen.visibleFrame
            let ratio = min(2.3, max(0.55, aspect))
            let maxWidth = visible.width * 0.88
            let maxHeight = visible.height * 0.84
            // Keep modest controls/queue overhead while adapting the image.
            let width = min(maxWidth, max(560, min(880, 545 * ratio + 100)))
            let height = min(maxHeight, max(490, min(780, (width - 50) / ratio + 120)))
            let old = window.frame
            var frame = CGRect(x: old.midX - width / 2, y: old.midY - height / 2,
                               width: width, height: height)
            frame.origin.x = min(max(visible.minX, frame.origin.x), visible.maxX - width)
            frame.origin.y = min(max(visible.minY, frame.origin.y), visible.maxY - height)
            if reduceMotion {
                window.setFrame(frame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.28
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                    window.animator().setFrame(frame, display: true)
                }
            }
        }
    }
}
