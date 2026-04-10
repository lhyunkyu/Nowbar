import Cocoa
import SwiftUI

/// 알림 전용 팝업 윈도우 — 나우바와 완전히 독립적으로 생성/소멸
class AlertWindowManager: ObservableObject {
    static let shared = AlertWindowManager()

    @Published var isVisible: Bool = false

    private var alertWindow: NSWindow?
    private init() {}

    func show(_ notification: NowBarNotification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dismiss()

            guard let screen = NSScreen.screens.first else { return }
            let sf = screen.frame

            let winWidth: CGFloat  = 300
            let winHeight: CGFloat = 80

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
            win.contentView        = NSHostingView(rootView: AlertPopupView(notification: notification))

            self.alertWindow = win
            self.isVisible   = true
            win.orderFrontRegardless()
            HapticManager.shared.playNowBarAppear()
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [weak self] in
            self?.alertWindow?.orderOut(nil)
            self?.alertWindow = nil
            self?.isVisible   = false
        }
    }
}
