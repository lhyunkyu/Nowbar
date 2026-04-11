import SwiftUI

struct AlertPopupView: View {
    let notification: NowBarNotification

    @State private var dropProgress: CGFloat = 0.0
    @State private var offsetY: CGFloat      = -8
    @State private var cornerRadius: CGFloat = 0.0

    var body: some View {
        ZStack(alignment: .top) {
            // 연결 목 없음 — pill만 표시

            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 290, height: 44)
                    .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)

                NotifRow(n: notification)
                    .frame(width: 290, height: 44)
                    .clipped()
            }
            .scaleEffect(x: dropProgress, y: dropProgress, anchor: .top)
            .offset(y: offsetY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .onAppear {
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
