import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {

    var notchBarWindow: NSWindow?
    var nowBarWindow: NSWindow?
    var sideBarWindow: NSWindow?
    var mouseMonitor: Any?
    var clickMonitor: Any?

    let notchWidth: CGFloat     = 190
    let notchHeight: CGFloat    = 37
    let notchHalfWidth: CGFloat = 120
    let nowBarWidth: CGFloat    = 520
    let nowBarHeight: CGFloat   = 160

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🚀 NowBar 시작")
        requestAccessibilityIfNeeded()

        _ = NotificationManager.shared
        _ = NowPlayingManager.shared
        _ = PowerManager.shared

        setupNotchBarWindow()
        setupNowBarWindow()
        setupSideBarWindow()
        startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
    }

    func requestAccessibilityIfNeeded() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        NSLog("🔐 손쉬운 사용 권한: \(AXIsProcessTrustedWithOptions(options))")
    }

    func setupNotchBarWindow() {
        guard let screen = NSScreen.screens.first else { return }
        let sf = screen.frame
        let rect = NSRect(x: (sf.width - notchWidth) / 2, y: sf.height - notchHeight, width: notchWidth, height: notchHeight)
        let win = makeWindow(rect: rect, ignoresMouse: false)
        win.contentView = NSHostingView(rootView: NotchBarView())
        notchBarWindow = win
        win.orderFrontRegardless()
    }

    func setupNowBarWindow() {
        guard let screen = NSScreen.screens.first else { return }
        let sf = screen.frame
        let rect = NSRect(x: (sf.width - nowBarWidth) / 2, y: sf.height - notchHeight - nowBarHeight, width: nowBarWidth, height: nowBarHeight)
        let win = makeWindow(rect: rect, ignoresMouse: true)
        win.contentView = NSHostingView(rootView: NowBarOverlayView())
        nowBarWindow = win
        win.orderFrontRegardless()
    }

    func setupSideBarWindow() {
        guard let screen = NSScreen.screens.first else { return }
        let sf = screen.frame
        let rect = NSRect(x: sf.width / 2 + notchHalfWidth + 8, y: sf.height - notchHeight, width: 220, height: notchHeight)
        let win = makeWindow(rect: rect, ignoresMouse: true)
        win.contentView = NSHostingView(rootView: SideBarNowPlayingView())
        sideBarWindow = win
        win.orderFrontRegardless()
    }

    private func makeWindow(rect: NSRect, ignoresMouse: Bool) -> NSWindow {
        guard let screen = NSScreen.screens.first else { fatalError() }
        let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        win.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.backgroundColor    = .clear
        win.isOpaque           = false
        win.hasShadow          = false
        win.ignoresMouseEvents = ignoresMouse
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return win
    }

    func startMonitoring() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updateProximity()
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateProximity()
            return event
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first else { return }
            let sf = screen.frame
            let notchRect = NSRect(x: sf.width / 2 - self.notchHalfWidth, y: sf.height - self.notchHeight, width: self.notchWidth, height: self.notchHeight)
            if !notchRect.contains(mouse) {
                DispatchQueue.main.async { NotchState.shared.isExpanded = false }
            }
        }
    }

    func updateProximity() {
        guard let screen = NSScreen.screens.first else { return }
        let sf    = screen.frame
        let mouse = NSEvent.mouseLocation

        // 노치 rect 안에 있을 때만 호버 활성화
        // 노치 바로 아래 20pt까지 허용 (나우바 드롭다운 탐색 가능)
        let notchRect = NSRect(
            x: sf.width / 2 - notchHalfWidth,
            y: sf.height - notchHeight,  // 아래로 20pt 여유
            width: notchWidth,
            height: notchHeight + 20
        )

        let proximity: CGFloat = notchRect.contains(mouse) ? 1.0 : 0.0

        DispatchQueue.main.async {
            NotchState.shared.proximity = proximity
        }
    }
}
