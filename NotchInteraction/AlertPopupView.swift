import SwiftUI

/// 알림 전용 팝업 뷰 — 노치에서 뽈롱 나왔다가 자동으로 들어감
struct AlertPopupView: View {
    let notification: NowBarNotification

    @State private var dropProgress: CGFloat = 0.0
    @State private var offsetY: CGFloat      = -8
    @State private var cornerRadius: CGFloat = 0.0

    var body: some View {
        ZStack(alignment: .top) {

            // 노치 연결 목
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black)
                .frame(width: 52, height: 8)
                .opacity(Double(dropProgress))

            // 알림 pill
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 280, height: 44)
                    .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)

                NotifRow(n: notification)
            }
            .scaleEffect(x: dropProgress, y: dropProgress, anchor: .top)
            .offset(y: offsetY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // 등장 애니메이션
            withAnimation(.spring(response: 0.38, dampingFraction: 0.58)) {
                dropProgress = 1.0
                offsetY      = 8
                cornerRadius = 22
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.42)) {
                    offsetY = 4
                }
            }

            // 2초 후 퇴장 애니메이션 → 윈도우 제거
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    dropProgress = 0.0
                    offsetY      = -8
                    cornerRadius = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    AlertWindowManager.shared.dismiss()
                }
            }
        }
    }
}
