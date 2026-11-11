import AppKit
import SwiftUI

struct ScrollViewportReader: NSViewRepresentable {
    var update: (CGSize) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.update = update
        view.connect()
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.disconnect() }

    final class Probe: NSView {
        var update: ((CGSize) -> Void)?
        private weak var clip: NSClipView?
        private var lastSize: CGSize?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            connect()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
        }

        func connect() {
            let next = window == nil ? nil : enclosingScrollView?.contentView
            guard next !== clip else { return }
            disconnect()
            guard let next else { return }
            clip = next
            next.postsBoundsChangedNotifications = true
            next.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(viewportChanged), name: name, object: next)
            }
            report()
        }

        func disconnect() {
            if let clip {
                for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                    NotificationCenter.default.removeObserver(self, name: name, object: clip)
                }
            }
            clip = nil
            lastSize = nil
        }

        @objc private func viewportChanged(_ notification: Notification) { report() }

        private func report() {
            guard let clip, clip.bounds.size != lastSize else { return }
            let size = clip.bounds.size
            lastSize = size
            DispatchQueue.main.async { [weak self, weak clip] in
                guard let self, let clip, self.clip === clip, clip.bounds.size == size else { return }
                self.update?(size)
            }
        }
    }
}
