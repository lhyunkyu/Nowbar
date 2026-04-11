import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {

    var notchBarWindow: NSWindow?
    var nowBarWindow: NSWindow?
    var sideBarWindow: NSWindow?
    var mouseMonitor: Any?
    var clickMonitor: Any?

    let notchWidth: CGFloat     = 160
    let notchHeight: CGFloat    = 37
    let notchHalfWidth: CGFloat = 100
    let nowBarWidth: CGFloat    = 520
    let nowBarHeight: CGFloat   = 160

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🚀 NowBar 시작")
        requestAccessibilityIfNeeded()

        // 싱글톤 명시적 초기화
        _ = NotificationManager.shared
        _ = NowPlayingManager.shared
        _ = PowerManager.shared

        setupNotchBarWindow()
        setupNowBarWindow()
        setupSideBarWindow()
        startMonitoring()

        // 테스트: 3초 후 알림 강제 발사
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            NSLog("🧪 테스트 알림 발사")
            AlertWindowManager.shared.show(NowBarNotification(
                icon: "bolt.fill",
                iconColor: .yellow,
                title: "테스트 알림",
                badge: "작동중",
                badgeColor: .green
            ))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
    }

    func requestAccessibilityIfNeeded() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        NSLog("🔐 손쉬운 사용 권한: \(AXIsProcessTrustedWithOptions(options))")
    }

    // MARK: - 노치 바 (클릭 감지)

    func setupNotchBarWindow() {
        guard let screen = NSScreen.screens.first else { return }
        let sf = screen.frame
        let rect = NSRect(
            x: (sf.width - notchWidth) / 2,
            y: sf.height - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        let win = makeWindow(rect: rect, ignoresMouse: false)
        win.contentView = NSHostingView(rootView: NotchBarView())
        notchBarWindow = win
        win.orderFrontRegardless()
        NSLog("✅ 노치 바: \(rect)")
    }

    // MARK: - 나우바 드롭다운

    func setupNowBarWindow() {
        guard let screen = NSScreen.screens.first else { return }
        let sf = screen.frame
        let rect = NSRect(
            x: (sf.width - nowBarWidth) / 2,
            y: sf.height - notchHeight - nowBarHeight,
            width: nowBarWidth,
            height: nowBarHeight
        )
        let win = makeWindow(rect: rect, ignoresMouse: true)
        win.contentView = NSHostingView(rootView: NowBarOverlayView())
        nowBarWindow = win
        win.orderFrontRegardless()
        NSLog("✅ 나우바: \(rect)")
    }

    // MARK: - 사이드바 알약

    func setupSideBarWindow() {
        guard let screen = NSScreen.screens.first else { return }
        let sf = screen.frame
        let rect = NSRect(
            x: sf.width / 2 + notchHalfWidth + 8,
            y: sf.height - notchHeight,
            width: 220,
            height: notchHeight
        )
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

    // MARK: - 마우스 모니터링

    func startMonitoring() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in self?.updateProximity() }

        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateProximity()
            return event
        }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first else { return }
            let sf = screen.frame
            let notchRect = NSRect(
                x: sf.width / 2 - self.notchHalfWidth,
                y: sf.height - self.notchHeight,
                width: self.notchWidth,
                height: self.notchHeight
            )
            if !notchRect.contains(mouse) {
                DispatchQueue.main.async { NotchState.shared.isExpanded = false }
            }
        }

        NSLog("✅ 모니터링 시작")
    }

    func updateProximity() {
        guard let screen = NSScreen.screens.first else { return }
        let sf    = screen.frame
        let mouse = NSEvent.mouseLocation
        let dx    = mouse.x - sf.width / 2
        let dy    = mouse.y - (sf.height - notchHeight / 2)
        let dist  = sqrt(dx * dx + dy * dy)
        let proximity = max(0.0, min(1.0, 1.0 - dist / 150))
        DispatchQueue.main.async { NotchState.shared.proximity = proximity }
    }
}
