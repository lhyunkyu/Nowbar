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

    /// 사이드바 나우바(알약) 확장 상태. true면 노치 아래로 3배 크기로 드롭다운.
    @Published var isSideBarExpanded: Bool = false {
        didSet {
            if oldValue != isSideBarExpanded {
                NotificationCenter.default.post(name: .nowBarProximityChanged, object: nil)
            }
        }
    }

    /// 사이드바 알약이 실제로 화면에 보이는지 여부.
    /// AppDelegate가 이 값을 구독해서 sideBarWindow의 ignoresMouseEvents를 토글함
    /// (false면 클릭이 아래 윈도우/알림센터로 통과)
    @Published var isSideBarRendered: Bool = false

    private init() {}
}
