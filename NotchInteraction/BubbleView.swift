import SwiftUI
import AppKit

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
    /// nil → 글씨 길이 / 3 초 (최소 1.2초), 0 → 무한 유지
    var duration: Double? = nil
    /// true → 표시 중 통통 바운스 애니메이션 활성 (기본값 true)
    var bouncing: Bool = true

    @State private var isVisible:   Bool    = false
    @State private var hideTask:    DispatchWorkItem? = nil
    @State private var bounceY:     CGFloat = 0
    @State private var bounceToken: UUID    = UUID()

    // 글씨 길이 기반 자동 지속 시간 (0 = 무한)
    private var autoDuration: Double {
        if let d = duration { return d }
        return max(1.2, Double(text.count) / 3.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 위 방향 삼각 포인터
            BubbleArrowShape()
                .fill(Color.black.opacity(0.55))
                .frame(width: 14, height: 11)

            // 말풍선 본체
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 22)
                .padding(.vertical, 9)
                .frame(minWidth: 140)
                .background(
                    ZStack {
                        BubbleBlurBackground().clipShape(Capsule())
                        Capsule().fill(Color.black.opacity(0.55))
                    }
                )
        }
        // 위에서 아래로 뽈롱: .top 앵커에서 scale + 살짝 위 offset에서 등장
        .scaleEffect(isVisible ? 1.0 : 0.2, anchor: .top)
        .offset(y: (isVisible ? 0 : -10) + bounceY)
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
        // 등장 애니메이션 끝난 후 통통 바운스 시작 (bouncing == true 일 때만)
        if bouncing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                startBounce()
            }
        }
        scheduleHide()
    }

    // MARK: - 바운스 시작
    private func startBounce() {
        let token = UUID()
        bounceToken = token
        runBounceLoop(token: token)
    }

    private func runBounceLoop(token: UUID) {
        guard token == bounceToken, isVisible else { return }
        // 아래로 딱 내려가기
        withAnimation(.spring(response: 0.22, dampingFraction: 0.30)) {
            bounceY = 7
        }
        // 다시 바닥으로 탁 내려오기
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard token == bounceToken else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.30)) {
                bounceY = 0
            }
            // 잠깐 쉬고 반복
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.60) {
                runBounceLoop(token: token)
            }
        }
    }

    // MARK: - 바운스 정지
    private func stopBounce() {
        bounceToken = UUID() // 루프 무효화
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { bounceY = 0 }
    }

    // MARK: - 자동 퇴장 스케줄
    private func scheduleHide() {
        // duration == 0 이면 무한 유지 (isShowing = false 로 직접 닫아야 함)
        guard autoDuration > 0 else { return }
        let task = DispatchWorkItem { [self] in
            animateOut {
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
        stopBounce()
        // 뽈롱 퇴장: 위로 쏙 들어가는 느낌
        withAnimation(.spring(response: 0.30, dampingFraction: 0.58)) {
            isVisible = false
        }
        completion?()
    }
}

// MARK: - 백드롭 블러 (NSVisualEffectView 래핑)
private struct BubbleBlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material     = .hudWindow      // 어두운 반투명 소재
        v.blendingMode = .behindWindow   // 뒤 콘텐츠 블러
        v.state        = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - 삼각 포인터 Shape (끝부분 둥글게)
private struct BubbleArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tipRadius:   CGFloat = 4
        let tip         = CGPoint(x: rect.midX, y: rect.minY)
        let bottomLeft  = CGPoint(x: rect.minX, y: rect.maxY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)

        p.move(to: bottomLeft)
        // 왼쪽 아래 → 꼭짓점(둥글게) → 오른쪽 아래
        p.addArc(tangent1End: tip, tangent2End: bottomRight, radius: tipRadius)
        p.addLine(to: bottomRight)
        p.closeSubpath()
        return p
    }
}
