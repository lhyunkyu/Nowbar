import Foundation
import AppKit

/// 배터리 레벨/충전 상태 저장소 — 감시는 NotificationManager가 전담
class PowerManager: ObservableObject {
    static let shared = PowerManager()

    @Published var isCharging: Bool  = false
    @Published var batteryLevel: Int = 100

    private init() {}
}
