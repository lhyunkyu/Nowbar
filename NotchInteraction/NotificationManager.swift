import Foundation
import AppKit
import SwiftUI
import Network
import IOBluetooth
import IOKit.ps

// MARK: - 통합 알림 모델

struct NowBarNotification {
    var icon: String
    var iconColor: NowBarColor
    var title: String
    var badge: String?
    var badgeColor: NowBarColor?
}

enum NowBarColor {
    case blue, green, yellow, red, white, gray

    var swiftColor: Color {
        switch self {
        case .blue:   return .blue.opacity(0.9)
        case .green:  return .green.opacity(0.9)
        case .yellow: return .yellow
        case .red:    return .red
        case .white:  return .white.opacity(0.85)
        case .gray:   return .white.opacity(0.45)
        }
    }
}

// MARK: - 통합 알림 매니저

class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    private var queue: [NowBarNotification] = []
    private var isShowing = false
    private var hideTimer: Timer?

    // Wi-Fi
    private var networkMonitor: NWPathMonitor?
    private var lastWifiConnected: Bool? = nil
    private var lastSSID: String = "Wi-Fi"

    // 배터리
    private var batteryRunLoop: CFRunLoopSource?
    private var lowBatteryAlerted = false
    private var lastCharging: Bool? = nil
    private var lastBatteryLevel: Int = 100

    // 블루투스
    private var btConnectNotification: IOBluetoothUserNotification?
    private var btDisconnectMap: [ObjectIdentifier: IOBluetoothUserNotification] = [:]
    private var initialDevices: Set<String> = []
    private var btReady = false
    // 디바운싱: 기기 주소별 마지막 이벤트 시각
    private var btLastEventTime: [String: Date] = [:]
    private let btDebounceInterval: TimeInterval = 1.5  // 1.5초 내 중복 무시

    private override init() {
        super.init()
        startBatteryMonitoring()
        startWifiMonitoring()
        startBluetoothMonitoring()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(proximityChanged),
            name: .nowBarProximityChanged,
            object: nil
        )
    }

    // MARK: - 호버 감지

    @objc private func proximityChanged() {
        let isHovering = NotchState.shared.proximity > 0.08 || NotchState.shared.isExpanded
        if !isHovering && !isShowing && !queue.isEmpty {
            let next = queue.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.show(next)
            }
        }
    }

    // MARK: - 알림 큐

    func push(_ n: NowBarNotification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isHovering = NotchState.shared.proximity > 0.08 || NotchState.shared.isExpanded
            if isHovering || self.isShowing {
                self.queue.append(n)
            } else {
                self.show(n)
            }
        }
    }

    private func show(_ n: NowBarNotification) {
        hideTimer?.invalidate()
        isShowing = true
        AlertWindowManager.shared.show(n)

        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.35, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.onAlertDismissed() }
        }
    }

    private func onAlertDismissed() {
        isShowing = false
        guard !queue.isEmpty else { return }
        let isHovering = NotchState.shared.proximity > 0.08 || NotchState.shared.isExpanded
        if isHovering { return }
        let next = queue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.show(next)
        }
    }

    // MARK: - 배터리

    private func startBatteryMonitoring() {
        readBattery(notify: false)
        let ctx = Unmanaged.passRetained(self).toOpaque()
        batteryRunLoop = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<NotificationManager>.fromOpaque(ctx).takeUnretainedValue().readBattery(notify: true)
        }, ctx).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), batteryRunLoop, .defaultMode)
    }

    private func readBattery(notify: Bool) {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources  = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
            let source   = sources.first,
            let info     = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        else { return }

        let level    = info[kIOPSCurrentCapacityKey] as? Int ?? 100
        let charging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            PowerManager.shared.batteryLevel = level
            PowerManager.shared.isCharging   = charging

            if !notify {
                self.lastCharging     = charging
                self.lastBatteryLevel = level
                return
            }

            if let last = self.lastCharging, last != charging {
                self.push(NowBarNotification(
                    icon: charging ? "bolt.fill" : "bolt.slash.fill",
                    iconColor: charging ? .yellow : .gray,
                    title: charging ? "충전 중" : "충전 해제",
                    badge: "\(level)%",
                    badgeColor: charging ? .green : .white
                ))
            }
            self.lastCharging     = charging
            self.lastBatteryLevel = level

            if level <= 15 && !charging && !self.lowBatteryAlerted {
                self.lowBatteryAlerted = true
                self.push(NowBarNotification(
                    icon: level <= 5 ? "battery.0" : "battery.25",
                    iconColor: level <= 5 ? .red : .yellow,
                    title: "배터리 부족",
                    badge: "\(level)%",
                    badgeColor: level <= 5 ? .red : .yellow
                ))
            }
            if charging { self.lowBatteryAlerted = false }
        }
    }

    // MARK: - Wi-Fi

    private func startWifiMonitoring() {
        if let ssid = currentSSID() { lastSSID = ssid }

        networkMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied

            if self.lastWifiConnected == nil {
                self.lastWifiConnected = connected
                if connected, let ssid = self.currentSSID() { self.lastSSID = ssid }
                return
            }
            guard self.lastWifiConnected != connected else { return }
            self.lastWifiConnected = connected

            if connected {
                let ssid = self.currentSSID() ?? self.lastSSID
                self.lastSSID = ssid
                self.push(NowBarNotification(icon: "wifi", iconColor: .blue, title: ssid, badge: "연결됨", badgeColor: .blue))
            } else {
                self.push(NowBarNotification(icon: "wifi.slash", iconColor: .gray, title: self.lastSSID, badge: "해제됨", badgeColor: .gray))
            }
        }
        networkMonitor?.start(queue: DispatchQueue.global(qos: .background))
    }

    private func currentSSID() -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/networksetup"
        task.arguments  = ["-getairportnetwork", "en0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let range = output.range(of: "Current Wi-Fi Network: ") {
            let ssid = String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ssid.isEmpty ? nil : ssid
        }
        return nil
    }

    // MARK: - 블루투스

    private func startBluetoothMonitoring() {
        // 시작 시 이미 연결된 기기 수집
        let connected = IOBluetoothDevice.pairedDevices()?
            .compactMap { $0 as? IOBluetoothDevice }
            .filter { $0.isConnected() }
            .compactMap { $0.addressString } ?? []
        initialDevices = Set(connected)

        // 0.3초 후 등록 (시작 직후 콜백 폭탄 방지)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.btConnectNotification = IOBluetoothDevice.register(
                forConnectNotifications: self,
                selector: #selector(self.btConnected(_:device:))
            )
            self.btReady = true
        }
    }

    @objc private func btConnected(_ n: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // 해제 알림 등록
        let disc = device.register(forDisconnectNotification: self, selector: #selector(btDisconnected(_:device:)))
        btDisconnectMap[ObjectIdentifier(device)] = disc

        // 초기 기기 무시
        if let addr = device.addressString, initialDevices.contains(addr) {
            initialDevices.remove(addr)
            return
        }
        guard btReady else { return }

        // 블루투스 자체 on/off 시 name이 nil인 경우 무시
        guard let name = device.name, !name.isEmpty else { return }

        // 디바운싱: 같은 기기에서 1.5초 내 중복 이벤트 무시
        let addr = device.addressString ?? name
        let now = Date()
        if let last = btLastEventTime[addr], now.timeIntervalSince(last) < btDebounceInterval { return }
        btLastEventTime[addr] = now

        NSLog("🔵 연결: \(name)")
        push(NowBarNotification(icon: iconForBTDevice(device), iconColor: .blue, title: name, badge: "연결됨", badgeColor: .blue))
    }

    @objc private func btDisconnected(_ n: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        btDisconnectMap.removeValue(forKey: ObjectIdentifier(device))
        guard btReady else { return }

        // 블루투스 자체 on/off 시 name이 nil인 경우 무시
        guard let name = device.name, !name.isEmpty else { return }

        // 디바운싱
        let addr = device.addressString ?? name
        let now = Date()
        if let last = btLastEventTime[addr], now.timeIntervalSince(last) < btDebounceInterval { return }
        btLastEventTime[addr] = now

        NSLog("🔵 해제: \(name)")
        push(NowBarNotification(icon: iconForBTDevice(device), iconColor: .gray, title: name, badge: "해제됨", badgeColor: .gray))
    }

    private func iconForBTDevice(_ device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        let cod  = (device.classOfDevice >> 8) & 0x1F

        if name.contains("airpods")                                               { return "airpodspro" }
        if name.contains("headphone") || name.contains("headset") ||
           name.contains("buds") || name.contains("wh-") || name.contains("wf-") { return "headphones" }
        if name.contains("keyboard")                                              { return "keyboard" }
        if name.contains("mouse")                                                 { return "computermouse" }
        if name.contains("trackpad")                                              { return "rectangle.and.hand.point.up.left" }
        if name.contains("speaker") || name.contains("soundbar")                 { return "hifispeaker.fill" }
        if name.contains("watch")                                                 { return "applewatch" }
        if name.contains("iphone") || name.contains("sm-") || name.contains("phone") { return "iphone" }
        if name.contains("pad")                                                  { return "ipad" }
        if name.contains("controller") || name.contains("dualsense") ||
           name.contains("dualshock") || name.contains("xbox")                   { return "gamecontroller.fill" }
        switch cod {
        case 0x04: return "headphones"
        case 0x05: return "keyboard"
        case 0x0075: return "iphone"
        default:   return "bluetooth"
        }
    }
}

// MARK: - Notification 이름

extension Notification.Name {
    static let nowBarProximityChanged = Notification.Name("nowBarProximityChanged")
}
