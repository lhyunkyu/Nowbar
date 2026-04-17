import SwiftUI
import CoreImage

// MARK: - NSImage 대표 색상 추출
private extension NSImage {
    func dominantColor() -> NSColor {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .black
        }
        let ci = CIImage(cgImage: cgImage)
        let extent = ci.extent
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(
                x: extent.origin.x, y: extent.origin.y,
                z: extent.size.width, w: extent.size.height
            )
        ]), let out = filter.outputImage else { return .black }

        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            out, toBitmap: &px, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return NSColor(
            calibratedRed: CGFloat(px[0]) / 255,
            green:         CGFloat(px[1]) / 255,
            blue:          CGFloat(px[2]) / 255,
            alpha:         1
        )
    }
}

// MARK: - 마퀴 스크롤 텍스트
struct MarqueeText: View {
    let text: String
    let maxWidth: CGFloat
    let font: Font

    @State private var textWidth: CGFloat  = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var isScrolling: Bool   = false

    private var needsScroll: Bool { textWidth > maxWidth }

    var body: some View {
        ZStack(alignment: .leading) {
            // 실제 텍스트 (width 측정용 hidden)
            Text(text)
                .font(font)
                .fixedSize()
                .hidden()
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear   { textWidth = geo.size.width; scheduleScroll() }
                            .onChange(of: text) { _ in
                                textWidth = geo.size.width
                                scrollOffset = 0
                                isScrolling  = false
                                scheduleScroll()
                            }
                    }
                )

            // 보이는 텍스트
            Text(text)
                .font(font)
                .fixedSize()
                .offset(x: scrollOffset)
        }
        .frame(width: maxWidth, alignment: .leading)
        .clipped()
    }

    private func scheduleScroll() {
        guard needsScroll else { return }
        let scrollDist = textWidth - maxWidth + 16
        let duration   = Double(scrollDist) / 28.0   // 28pt/sec 속도

        // 1.2초 대기 → 왼쪽으로 스크롤 → 0.6초 대기 → 복귀 → 반복
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.linear(duration: duration)) {
                scrollOffset = -scrollDist
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.6) {
                withAnimation(.linear(duration: 0.4)) {
                    scrollOffset = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    scheduleScroll()  // 루프
                }
            }
        }
    }
}

// MARK: - 실시간 나우바
struct SideBarNowPlayingView: View {
    @ObservedObject var state      = NotchState.shared
    @ObservedObject var nowPlaying = NowPlayingManager.shared

    // isShowingBar 는 isPlaying 과 별도 - 딜레이 사라짐 처리
    @State private var appeared:     Bool  = false
    @State private var isShowingBar: Bool  = false
    @State private var waveAnimating: Bool = false
    @State private var accentColor: Color  = Color.black
    @State private var hideWorkItem: DispatchWorkItem? = nil

    var shouldRender: Bool {
        isShowingBar &&
        state.proximity <= 0.08 &&
        !state.isExpanded &&
        !AlertWindowManager.shared.isVisible
    }

    var body: some View {
        HStack(spacing: 7) {
            // 앨범 아트
            if let artwork = nowPlaying.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 22, height: 22)
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                }
            }

            // 마퀴 스크롤 제목
            MarqueeText(
                text: nowPlaying.title.isEmpty ? "" : nowPlaying.title,
                maxWidth: 70,
                font: .system(size: 11, weight: .semibold)
            )
            .foregroundColor(.white)

            // 뮤직 웨이브
            MusicWaveView(animating: waveAnimating)
                .frame(width: 14, height: 12)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            Capsule()
                .fill(accentColor)
        )
        // ── 물방울 팝 애니메이션 ──────────────────────────
        // appeared && shouldRender 일 때 1.0, 아니면 찌그러진 물방울 초기값
        .scaleEffect(
            x: appeared && shouldRender ? 1.0 : 0.05,
            y: appeared && shouldRender ? 1.0 : 0.15,
            anchor: .leading
        )
        .opacity(appeared && shouldRender ? 1 : 0)
        .animation(
            shouldRender
                // 물방울: 낮은 dampingFraction → 통통 튀는 느낌
                ? .spring(response: 0.50, dampingFraction: 0.38)
                // 노치로 복귀: 빠르고 깔끔하게
                : .spring(response: 0.24, dampingFraction: 0.90),
            value: shouldRender
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 6)

        // MARK: Lifecycle
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                appeared = true
            }
            if nowPlaying.isPlaying { triggerShow() }
        }
        .onChange(of: nowPlaying.isPlaying) { playing in
            if playing {
                triggerShow()
            } else {
                triggerHide()
            }
        }
        .onChange(of: nowPlaying.artwork) { _ in
            refreshAccentColor()
        }
        .onChange(of: nowPlaying.title) { _ in
            // 곡 바뀌면 색 갱신
            refreshAccentColor()
        }
    }

    // MARK: - Show / Hide 제어
    private func triggerShow() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isShowingBar  = true
        waveAnimating = true
        refreshAccentColor()
    }

    private func triggerHide() {
        // 1. 웨이브 멈춤
        waveAnimating = false

        // 2. 1.5초 후 바 사라짐
        let work = DispatchWorkItem {
            isShowingBar = false
            // 색은 유지하다가 완전히 사라진 뒤 리셋
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                accentColor = .black
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - 대표 색 추출
    private func refreshAccentColor() {
        guard let artwork = nowPlaying.artwork else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let raw      = artwork.dominantColor()
            let darkened = raw.blended(withFraction: 0.22, of: .black) ?? raw
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.5)) {
                    accentColor = Color(darkened)
                }
            }
        }
    }
}

// MARK: - 뮤직 웨이브 (외부에서 animating 제어)
struct MusicWaveView: View {
    var animating: Bool

    let heights: [CGFloat] = [0.45, 0.9, 0.6, 1.0, 0.7]
    let delays:  [Double]  = [0.0, 0.12, 0.22, 0.08, 0.18]

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: animating ? 12 * heights[i] : 2)
                    .animation(
                        animating
                            ? .easeInOut(duration: 0.42).repeatForever(autoreverses: true).delay(delays[i])
                            : .easeInOut(duration: 0.25),
                        value: animating
                    )
            }
        }
    }
}
