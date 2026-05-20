import SwiftUI

/// 노치 크기에 딱 맞는 고정 바 — 호버 감지 + 클릭으로 나우바 확장
struct NotchBarView: View {
    @ObservedObject var state = NotchState.shared

    var body: some View {
        Rectangle()
            .fill(Color.clear)   // 투명 — 클릭만 감지
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                // 호버로 이미 상세보기 전환되므로 탭은 닫기 전용
                if NotchState.shared.isExpanded {
                    HapticManager.shared.playNowBarDisappear()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                        NotchState.shared.isExpanded = false
                    }
                }
            }
    }
}
