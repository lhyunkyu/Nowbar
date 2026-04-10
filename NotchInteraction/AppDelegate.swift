import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {

    var notchBarWindow: NSWindow?   // 노치 크기 고정 바 (클릭 감지)
    var nowBarWindow: NSWindow?     // 클릭 시 확장되는 나우바
    var sideBarWindow: NSWindow?    // 노치 오른쪽 알약
    var mouseMonitor: Any?
    var clickMonitor: Any?

    // 맥북 노치 크기 (MacBook Pro 14"/16" 기준)
    let notchWidth: CGFloat         = 160
    let notchHeight: CGFloat        = 37
    let notchHalfWidth: CGFloat     = 100

    // 나우바 확장 크기
    let nowBarWidth: CGFloat        = 520
    let nowBarHeight: CGFloat       = 160

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🚀 NowBar 시작")
        requestAccessibilityIfNeeded()
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

    // MARK: - 노치 크기 고정 바 (클릭 감지용)

    func setupNotchBarWindow() {
        guard let screen = NSScreen.screens.first else { return }
        let sf = screen.frame

        // 노치 바 위치에 딱 맞게 — 클릭 이벤트 받아야 하므로 ignoresMouseEvents = false
        let rect = NSRect(
            x: (sf.width - notchWidth) / 2,
            y: sf.height - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        win.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.backgroundColor    = .clear
        win.isOpaque           = false
        win.hasShadow          = false
        win.ignoresMouseEvents = false   // 클릭 받아야 함
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.contentView        = NSHostingView(rootView: NotchBarView())
        notchBarWindow = win
        win.orderFrontRegardless()
        NSLog("✅ 노치 바 윈도우: \(rect)")
    }

    // MARK: - 나우바 확장 윈도우

    func setupNowBarWindow() {
        guard let screen = NSScreen.screens.first else { return }
        let sf = screen.frame

        let rect = NSRect(
            x: (sf.width - nowBarWidth) / 2,
            y: sf.height - notchHeight - nowBarHeight,
            width: nowBarWidth,
            height: nowBarHeight
        )
        let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        win.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.backgroundColor    = .clear
        win.isOpaque           = false
        win.hasShadow          = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.contentView        = NSHostingView(rootView: NowBarOverlayView())
        nowBarWindow = win
        win.orderFrontRegardless()
        NSLog("✅ 나우바 윈도우: \(rect)")
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
        let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        win.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        win.backgroundColor    = .clear
        win.isOpaque           = false
        win.hasShadow          = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.contentView        = NSHostingView(rootView: SideBarNowPlayingView())
        sideBarWindow = win
        win.orderFrontRegardless()
    }

    // MARK: - 마우스 + 클릭 모니터링

    func startMonitoring() {
        // 마우스 이동 감지 (hover)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in self?.updateProximity() }

        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateProximity()
            return event
        }

        // 전역 클릭 감지 — 노치 바 밖 클릭 시 나우바 닫기
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
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
            // 노치 바 밖 클릭 시 닫기
            if !notchRect.contains(mouse) {
                DispatchQueue.main.async {
                    NotchState.shared.isExpanded = false
                }
            }
        }

        NSLog("✅ 모니터링 시작")
    }

    func updateProximity() {
        guard let screen = NSScreen.screens.first else { return }
        let sf    = screen.frame
        let mouse = NSEvent.mouseLocation

        let notchCX = sf.width / 2
        let notchCY = sf.height - notchHeight / 2
        let dx      = mouse.x - notchCX
        let dy      = mouse.y - notchCY
        let dist    = sqrt(dx * dx + dy * dy)
        let proximity = max(0.0, min(1.0, 1.0 - dist / 150))

        DispatchQueue.main.async {
            NotchState.shared.proximity = proximity
        }
    }
}
