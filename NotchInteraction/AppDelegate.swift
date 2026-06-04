import Cocoa
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    var notchBarWindow: NSWindow?
    var nowBarWindow: NSWindow?
    var sideBarWindow: NSWindow?
    var mouseMonitor: Any?
    var clickMonitor: Any?
    var localClickMonitor: Any?
    // NSEvent global monitor 대신 CGEventTap 사용 (LSUIElement 앱에서 keyDown 안정적 수신)
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    private var cancellables = Set<AnyCancellable>()

    // 메뉴바 아이콘
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?

    let notchWidth: CGFloat     = 190
    let notchHeight: CGFloat    = 37
    let notchHalfWidth: CGFloat = 120
    let nowBarWidth: CGFloat    = 520
    let nowBarHeight: CGFloat   = 160

    // 사이드바 윈도우 크기 (collapsed / expanded)
    let sideBarCollapsedWidth: CGFloat  = 220
    let sideBarExpandedWidth: CGFloat   = 340
    let sideBarExpandedHeight: CGFloat  = 180

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🚀 NowBar 시작")
        requestAccessibilityIfNeeded()

        _ = NotificationManager.shared
        _ = NowPlayingManager.shared
        _ = PowerManager.shared

        // NowBar 플러그인 등록 (추가 플러그인은 여기에 register 호출)
        NowBarPluginManager.shared.register(MusicNowBarPlugin.shared)

        setupNotchBarWindow()
        setupNowBarWindow()
        setupSideBarWindow()
        setupStatusItem()
        startMonitoring()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // 창 닫아도 앱 유지
    }

    // X 버튼 → 실제로 닫지 않고 숨기기만 (댕글링 포인터 방지)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = mouseMonitor      { NSEvent.removeMonitor(m) }
        if let m = clickMonitor      { NSEvent.removeMonitor(m) }
        if let m = localClickMonitor { NSEvent.removeMonitor(m) }
        teardownKeyboardEventTap()
    }

    func requestAccessibilityIfNeeded() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        NSLog("🔐 손쉬운 사용 권한: \(AXIsProcessTrustedWithOptions(options))")
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Nowbar")
            button.image?.isTemplate = true
            button.action = #selector(toggleSettingsWindow)
            button.target = self
        }
    }

    @objc func toggleSettingsWindow() {
        if let win = settingsWindow {
            // 이미 창이 있으면 보이기/숨기기 토글
            if win.isVisible {
                win.orderOut(nil)
            } else {
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        // 창 최초 생성
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Nowbar"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.contentView = NSHostingView(rootView: SettingsView())
        win.center()
        win.setFrameAutosaveName("NowbarSettings")
        win.isReleasedWhenClosed = false  // 닫혀도 메모리 유지
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
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
        let shadowPad: CGFloat = 20
        let rect = NSRect(x: (sf.width - nowBarWidth) / 2, y: sf.height - notchHeight - nowBarHeight, width: nowBarWidth, height: nowBarHeight + shadowPad)
        let win = makeWindow(rect: rect, ignoresMouse: true, keyable: true)
        win.contentView = NSHostingView(rootView: NowBarOverlayView())
        nowBarWindow = win
        win.orderFrontRegardless()

        // 상세보기 확장 시 key window 획득 → 로컬 키 모니터로 단축키 수신
        NotchState.shared.$isExpanded
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                guard let self else { return }
                if expanded {
                    self.nowBarWindow?.makeKeyAndOrderFront(nil)
                }
            }
            .store(in: &cancellables)
    }

    func setupSideBarWindow() {
        guard let screen = NSScreen.screens.first else { return }
        let sf = screen.frame
        let rect = NSRect(
            x: sf.width / 2 + notchHalfWidth + 8,
            y: sf.height - notchHeight,
            width: sideBarCollapsedWidth,
            height: notchHeight
        )
        // 시작 시에는 알약이 안 보이므로 클릭이 통과되도록 ignoresMouseEvents = true
        // 알약이 화면에 떠 있을 때만 isSideBarRendered 구독으로 false로 바뀜
        let win = makeWindow(rect: rect, ignoresMouse: true)
        win.contentView = NSHostingView(rootView: SideBarNowPlayingView())
        sideBarWindow = win
        win.orderFrontRegardless()

        // 확장 상태 변화 → 윈도우 프레임 리사이즈
        NotchState.shared.$isSideBarExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                self?.resizeSideBarWindow(expanded: expanded)
            }
            .store(in: &cancellables)

        // 활성 플러그인 수 변화 → 윈도우 높이 재계산 (축소 상태에서 다중 알약 쌓일 때)
        NowBarPluginManager.shared.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !NotchState.shared.isSideBarExpanded else { return }
                self.resizeSideBarWindow(expanded: false)
            }
            .store(in: &cancellables)

        // 알약 표시 여부 변화 → 클릭 통과 토글
        // (알약 안 보일 땐 알림센터 등 아래 요소가 클릭되어야 함)
        NotchState.shared.$isSideBarRendered
            .removeDuplicates()
            .sink { [weak self] rendered in
                self?.sideBarWindow?.ignoresMouseEvents = !rendered
            }
            .store(in: &cancellables)
    }

    /// 확장 상태 + 활성 플러그인 수에 따라 사이드바 윈도우 프레임 동적 계산.
    /// - 콜랩스: 알약 1개 → notchHeight(37), 2개 → 37 + (28+4), …
    /// - 확장: 확장 알약(116) + 나머지 콜랩스 알약 + 상하 여백
    func resizeSideBarWindow(expanded: Bool) {
        guard let win = sideBarWindow, let screen = NSScreen.screens.first else { return }
        let sf      = screen.frame
        let manager = NowBarPluginManager.shared
        let active  = manager.activePlugins

        let collapsedPillH: CGFloat = 28
        let expandedPillH:  CGFloat = 116
        let pillSpacing:    CGFloat = 4

        let width: CGFloat = expanded ? sideBarExpandedWidth : sideBarCollapsedWidth

        let height: CGFloat
        if active.isEmpty {
            height = notchHeight
        } else if expanded {
            // 상단 패딩 34 + 확장 알약 + 나머지 콜랩스 알약 + 하단 패딩 8
            let otherCount = max(0, active.count - 1)
            let contentH   = 34 + expandedPillH
                           + CGFloat(otherCount) * (collapsedPillH + pillSpacing)
            height = max(sideBarExpandedHeight, contentH + 8)
        } else {
            // 첫 알약은 notchHeight 안에 수직 중앙 정렬 → 추가 알약은 아래로 쌓임
            let extraCount = max(0, active.count - 1)
            height = notchHeight + CGFloat(extraCount) * (collapsedPillH + pillSpacing)
        }

        // top edge를 화면 상단(노치 상단)에 고정
        let newRect = NSRect(
            x: sf.width / 2 + notchHalfWidth + 8,
            y: sf.height - height,
            width: width,
            height: height
        )
        win.animator().setFrame(newRect, display: true, animate: true)
    }

    private func makeWindow(rect: NSRect, ignoresMouse: Bool, keyable: Bool = false) -> NSWindow {
        guard let screen = NSScreen.screens.first else { fatalError() }
        let win: NSWindow = keyable
            ? KeyableWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            : NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
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
            let notchRect    = NSRect(x: sf.width / 2 - self.notchHalfWidth, y: sf.height - self.notchHeight, width: self.notchWidth, height: self.notchHeight)
            let isInNowBar   = self.nowBarWindow?.frame.contains(mouse) ?? false
            // 노치 영역 + 나우바 알약 영역 바깥 클릭 → 상세보기 닫기
            if !notchRect.contains(mouse) && !isInNowBar {
                DispatchQueue.main.async { NotchState.shared.isExpanded = false }
            }

            // 사이드바가 확장된 상태에서 사이드바 윈도우 외부 클릭 → 전체 축소
            if NotchState.shared.isSideBarExpanded,
               let sideWin = self.sideBarWindow,
               !sideWin.frame.contains(mouse) {
                DispatchQueue.main.async {
                    NowBarPluginManager.shared.collapseAll()
                }
            }
        }

        // 앱 내부 다른 윈도우 클릭 시에도 사이드바 축소 처리
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if NotchState.shared.isSideBarExpanded,
               let sideWin = self.sideBarWindow,
               event.window !== sideWin {
                DispatchQueue.main.async {
                    NowBarPluginManager.shared.collapseAll()
                }
            }
            return event
        }

        // MARK: - 상세보기 키보드 단축키 (로컬 모니터)
        // nowBarWindow가 key window일 때(상세보기 확장 상태) 키 이벤트 처리
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NotchState.shared.isExpanded else { return event }
            let np = NowPlayingManager.shared
            switch event.keyCode {
            case 49:  // Space — 재생/일시정지
                np.playPause()
                return nil
            case 123: // ← 5초 뒤로 (곡 초반이면 이전 트랙)
                if np.position > 3 {
                    np.seek(to: max(0, np.position - 5))
                } else {
                    np.previousTrack()
                }
                return nil
            case 124: // → 5초 앞으로
                if np.duration > 0 { np.seek(to: min(np.duration, np.position + 5)) }
                return nil
            case 53:  // Escape — 상세보기 닫기
                NotchState.shared.isExpanded = false
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - CGEventTap 키보드 단축키
    // NSEvent.addGlobalMonitorForEvents는 LSUIElement 앱에서 keyDown 수신 불안정.
    // CGEventTap(.listenOnly)은 접근성 권한이 있으면 시스템 전역으로 안정적으로 수신.

    /// CGEventTap 콜백 — @convention(c) 필요하므로 static으로 선언 (캡처 불가)
    private static let keyTapCallback: CGEventTapCallBack = { _, type, event, _ in
        guard type == .keyDown, NotchState.shared.isExpanded else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        DispatchQueue.main.async {
            let np = NowPlayingManager.shared
            switch keyCode {
            case 49:  // Space — 재생/일시정지
                np.playPause()
            case 123: // ← 5초 뒤로 (곡 초반이면 이전 트랙)
                if np.position > 3 {
                    np.seek(to: max(0, np.position - 5))
                } else {
                    np.previousTrack()
                }
            case 124: // → 5초 앞으로
                guard np.duration > 0 else { return }
                np.seek(to: min(np.duration, np.position + 5))
            case 53:  // Escape — 상세보기 닫기
                NotchState.shared.isExpanded = false
            default:
                break
            }
        }
        return Unmanaged.passUnretained(event)
    }

    func setupKeyboardEventTap() {
        guard AXIsProcessTrusted() else {
            NSLog("⌨️ 접근성 권한 없음 — 키보드 단축키 비활성 (시스템 환경설정 > 손쉬운 사용 확인)")
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: AppDelegate.keyTapCallback,
            userInfo: nil
        ) else {
            NSLog("⌨️ CGEventTap 생성 실패")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        tapRunLoopSource = src
        NSLog("⌨️ 키보드 이벤트 탭 활성화")
    }

    func teardownKeyboardEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = tapRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
        }
        eventTap = nil
        tapRunLoopSource = nil
    }

    func updateProximity() {
        guard let screen = NSScreen.screens.first else { return }
        let sf    = screen.frame
        let mouse = NSEvent.mouseLocation

        let notchRect = NSRect(
            x: sf.width / 2 - notchHalfWidth,
            y: sf.height - notchHeight,
            width: notchWidth,
            height: notchHeight + 20
        )

        let isOverNotch  = notchRect.contains(mouse)
        let isOverNowBar = nowBarWindow?.frame.contains(mouse) ?? false

        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            let wasVisible = NotchState.shared.proximity > 0 || NotchState.shared.isExpanded

            // 나우바 알약 영역 위에 있을 때도 proximity 유지 (사라지지 않도록)
            let proximity: CGFloat = (isOverNotch || (isOverNowBar && wasVisible)) ? 1.0 : 0.0
            NotchState.shared.proximity = proximity

            // 나우바 알약 위로 이동 → 상세보기 자동 전환
            // isOverNotch 제외: 노치 영역과 nowBarWindow가 겹치는 구간에서 동시 트리거 방지
            if isOverNowBar && !isOverNotch && wasVisible && !NotchState.shared.isExpanded {
                NotchState.shared.isExpanded = true
            }
        }
    }
}

// MARK: - Key Window 가능한 오버레이 윈도우
// borderless NSWindow는 기본적으로 canBecomeKey = false.
// NowBar 상세보기 확장 시 key window가 되어 로컬 키 모니터로 단축키를 받기 위해 서브클래스 사용.
private class KeyableWindow: NSWindow {
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }
}
