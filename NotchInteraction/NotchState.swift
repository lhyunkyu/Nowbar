import SwiftUI

class NotchState: ObservableObject {
    static let shared = NotchState()

    @Published var proximity: CGFloat = 0.0 {
        didSet {
            // 호버 상태 변화 시 NotificationManager에 알림
            let wasHovering = oldValue > 0.08
            let isHovering  = proximity > 0.08
            if wasHovering != isHovering {
                NotificationCenter.default.post(name: .nowBarProximityChanged, object: nil)
            }
        }
    }

    @Published var isExpanded: Bool = false {
        didSet {
            if oldValue != isExpanded {
                NotificationCenter.default.post(name: .nowBarProximityChanged, object: nil)
            }
        }
    }

    private init() {}
}
