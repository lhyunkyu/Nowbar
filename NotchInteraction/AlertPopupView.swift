import SwiftUI

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

            // 알림 pill — 윈도우 top에서 아래로 충분히 내려서 그림자 공간 확보
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 290, height: 44)
                    // 그림자 반경 넉넉하게
                    .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)

                NotifRow(n: notification)
                    .frame(width: 290, height: 44)
                    .clipped()
            }
            .scaleEffect(x: dropProgress, y: dropProgress, anchor: .top)
            .offset(y: offsetY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)  // 연결 목 위 여백
        .onAppear {
            // 등장
            withAnimation(.spring(response: 0.38, dampingFraction: 0.58)) {
                dropProgress = 1.0
                offsetY      = 10
                cornerRadius = 22
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.42)) {
                    offsetY = 6
                }
            }

            // 2초 후 퇴장
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
