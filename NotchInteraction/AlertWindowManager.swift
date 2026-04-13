import Cocoa
import SwiftUI

class AlertWindowManager: ObservableObject {
    static let shared = AlertWindowManager()

    @Published var isVisible: Bool = false
    private var alertWindow: NSWindow?
    private init() {}

    func show(_ notification: NowBarNotification) {
        if Thread.isMainThread {
            _show(notification)
        } else {
            DispatchQueue.main.async { self._show(notification) }
        }
    }
    //MARK: - 나우바알림 랜더링 영역
    private func _show(_ notification: NowBarNotification) {
        alertWindow?.orderOut(nil)
        alertWindow = nil

        guard let screen = NSScreen.screens.first else { return }
        let sf = screen.frame

        let winWidth: CGFloat  = 360
        let winHeight: CGFloat = 110  // 그림자 잘림 방지용 충분한 높이

        let rect = NSRect(
            x: (sf.width - winWidth) / 2,
            y: sf.height - 37 - winHeight,
            width: winWidth,
            height: winHeight
        )

        let win = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 2)
        win.backgroundColor    = .clear
        win.isOpaque           = false
        win.hasShadow          = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let hostingView = NSHostingView(rootView: AlertPopupView(notification: notification))
        hostingView.frame = NSRect(origin: .zero, size: rect.size)
        win.contentView = hostingView

        alertWindow = win
        isVisible   = true
        win.orderFrontRegardless()

        // 윈도우 표시 후 햅틱 (렌더링과 함께)
        HapticManager.shared.playNowBarAppear()
    }

    func dismiss() {
        if Thread.isMainThread {
            _dismiss()
        } else {
            DispatchQueue.main.async { self._dismiss() }
        }
    }

    private func _dismiss() {
        alertWindow?.orderOut(nil)
        alertWindow = nil
        isVisible   = false
    }
}
