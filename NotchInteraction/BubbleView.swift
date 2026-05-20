import SwiftUI

// MARK: - 말풍선 버블
/// Figma: Design System > Bubble > Default
/// 위 방향 삼각 포인터 + 어두운 캡슐 텍스트.
/// 뭔가를 알려줄 때 노치/알약 근처에 띄워서 사용.
///
/// 사용 예:
/// ```swift
/// BubbleView(text: "재생 중인 음악이 없어요")
/// ```
struct BubbleView: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            // 위 방향 삼각 포인터
            BubbleArrowShape()
                .fill(Color.black.opacity(0.70))
                .frame(width: 12, height: 10)

            // 말풍선 본체
            Text(text)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
                .frame(minWidth: 122)
                .background(
                    Capsule().fill(Color.black.opacity(0.70))
                )
        }
    }
}

// MARK: - 삼각 포인터 Shape
private struct BubbleArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))    // 꼭짓점 (위)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) // 오른쪽 아래
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)) // 왼쪽 아래
        p.closeSubpath()
        return p
    }
}
