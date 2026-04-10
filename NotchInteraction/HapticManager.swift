import AppKit

class HapticManager {
    static let shared = HapticManager()
    private init() {}

    private let performer = NSHapticFeedbackManager.defaultPerformer

    /// 나우바 등장 시 햅틱
    func playNowBarAppear() {
        // 1타: 또렷한 탁 느낌
        performer.perform(.alignment, performanceTime: .now)

        // 2타: 바운스 느낌
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            self.performer.perform(.levelChange, performanceTime: .now)
        }
    }

    /// 나우바 사라질 때 햅틱
    func playNowBarDisappear() {
        performer.perform(.generic, performanceTime: .now)
    }
}
