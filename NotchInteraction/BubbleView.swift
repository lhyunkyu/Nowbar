import SwiftUI

// MARK: - 말풍선 버블
/// Figma: Design System > Bubble > Default
/// 위에서 아래로 뽈롱 등장, 위로 뽈롱 퇴장.
/// duration 미지정 시 글씨 길이 / 3 초 동안 유지.
///
/// 사용 예:
/// ```swift
/// // duration 자동 (글씨 길이 기반)
/// BubbleView(text: "재생 중인 음악이 없어요", isShowing: $showBubble)
///
/// // duration 직접 지정
/// BubbleView(text: "저장됨", isShowing: $showBubble, duration: 1.5)
/// ```
struct BubbleView: View {
    let text: String
    @Binding var isShowing: Bool
    /// nil → 글씨 길이 / 3 초 (최소 1.2초)
    var duration: Double? = nil

    @State private var isVisible:  Bool = false
    @State private var hideTask:   DispatchWorkItem? = nil

    // 글씨 길이 기반 자동 지속 시간
    private var autoDuration: Double {
        duration ?? max(1.2, Double(text.count) / 3.0)
    }

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
        // 위에서 아래로 뽈롱: .top 앵커에서 scale + 살짝 위 offset에서 등장
        .scaleEffect(isVisible ? 1.0 : 0.2, anchor: .top)
        .offset(y: isVisible ? 0 : -10)
        .opacity(isVisible ? 1.0 : 0.0)
        .onAppear {
            if isShowing { animateIn() }
        }
        .onChange(of: isShowing) { showing in
            if showing {
                animateIn()
            } else {
                animateOut(completion: nil)
            }
        }
    }

    // MARK: - 등장
    private func animateIn() {
        hideTask?.cancel()
        // 뽈롱 등장: dampingFraction 낮춰서 탄성 효과
        withAnimation(.spring(response: 0.40, dampingFraction: 0.52)) {
            isVisible = true
        }
        scheduleHide()
    }

    // MARK: - 자동 퇴장 스케줄
    private func scheduleHide() {
        let task = DispatchWorkItem { [self] in
            animateOut {
                // 애니메이션 끝난 뒤 isShowing 동기화
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isShowing = false
                }
            }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDuration, execute: task)
    }

    // MARK: - 퇴장
    private func animateOut(completion: (() -> Void)?) {
        hideTask?.cancel()
        // 뽈롱 퇴장: 위로 쏙 들어가는 느낌
        withAnimation(.spring(response: 0.30, dampingFraction: 0.58)) {
            isVisible = false
        }
        completion?()
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
