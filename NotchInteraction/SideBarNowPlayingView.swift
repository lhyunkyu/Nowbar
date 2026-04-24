import SwiftUI
import CoreImage

// MARK: - NSImage 대표 색상 추출
private extension NSImage {
    func dominantColor() -> NSColor {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .black }
        let ci = CIImage(cgImage: cgImage)
        let extent = ci.extent
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(x: extent.origin.x, y: extent.origin.y,
                                        z: extent.size.width, w: extent.size.height)
        ]), let out = filter.outputImage else { return .black }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(out, toBitmap: &px, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return NSColor(calibratedRed: CGFloat(px[0]) / 255,
                       green: CGFloat(px[1]) / 255,
                       blue:  CGFloat(px[2]) / 255, alpha: 1)
    }
}

// MARK: - PreferenceKey (텍스트 너비 측정용)
private struct TextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - 뉴스 티커 스타일 연속 스크롤 텍스트
struct TickerText: View {
    let text: String
    let maxWidth: CGFloat
    let font: Font
    var color: Color = .white

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat    = 0
    @State private var token: UUID        = UUID()   // 루프 취소 토큰

    private let gap: CGFloat = 32
    private var needsTicker: Bool { textWidth > maxWidth }
    private var loopWidth: CGFloat { textWidth + gap }
    private var duration: Double   { Double(loopWidth) / 35.0 }

    var body: some View {
        ZStack(alignment: .leading) {
            // 숨김 측정용 (PreferenceKey로 너비 전달)
            Text(text)
                .font(font).fixedSize().hidden()
                .overlay(GeometryReader { geo in
                    Color.clear.preference(key: TextWidthKey.self, value: geo.size.width)
                })

            if needsTicker {
                HStack(spacing: gap) {
                    Text(text).font(font).fixedSize().foregroundColor(color)
                    Text(text).font(font).fixedSize().foregroundColor(color)
                }
                .offset(x: offset)
            } else {
                Text(text).font(font).fixedSize().foregroundColor(color)
            }
        }
        .frame(width: maxWidth, alignment: .leading)
        .clipped()
        // 레이아웃 패스 후 정확한 너비 수신
        .onPreferenceChange(TextWidthKey.self) { width in
            guard abs(width - textWidth) > 0.5 else { return }
            textWidth = width
            restartTicker()
        }
    }

    private func restartTicker() {
        // 새 토큰 발급 → 이전 루프의 asyncAfter 콜백이 실행되어도 무시됨
        let newToken = UUID()
        token = newToken

        // offset 즉시 리셋 (애니메이션 없이)
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { offset = 0 }

        guard needsTicker else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard token == newToken else { return }
            runLoop(token: newToken)
        }
    }

    private func runLoop(token: UUID) {
        guard self.token == token else { return }

        withAnimation(.linear(duration: duration)) { offset = -loopWidth }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard self.token == token else { return }
            // 즉시 리셋 후 1.8초 대기하다가 다시 시작
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { offset = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                runLoop(token: token)
            }
        }
    }
}

// MARK: - 실시간 나우바
struct SideBarNowPlayingView: View {
    @ObservedObject var state      = NotchState.shared
    @ObservedObject var nowPlaying = NowPlayingManager.shared

    @State private var appeared:      Bool  = false
    @State private var isShowingBar:  Bool  = false
    @State private var waveAnimating: Bool  = false
    @State private var accentColor:   Color = .black
    @State private var fgColor:       Color = .white   // 배경 밝기에 따라 검정/흰색
    @State private var hideWorkItem:  DispatchWorkItem? = nil

    // 애니메이션용 상태
    @State private var barOffsetX:  CGFloat = -10
    @State private var barScaleX:   CGFloat = 0.05
    @State private var barScaleY:   CGFloat = 0.2
    @State private var barOpacity:  Double  = 0

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
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(fgColor.opacity(0.2)).frame(width: 22, height: 22)
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(fgColor.opacity(0.9))
                }
            }

            // 뉴스 티커 스크롤 제목
            TickerText(
                text:     nowPlaying.title.isEmpty ? "" : nowPlaying.title,
                maxWidth: 72,
                font:     .system(size: 11, weight: .semibold),
                color:    fgColor
            )

            // 뮤직 웨이브
            MusicWaveView(animating: waveAnimating, color: fgColor)
                .frame(width: 14, height: 12)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Capsule().fill(accentColor))
        // ── 오른쪽으로 튀어나오는 물방울 애니메이션
        .scaleEffect(x: barScaleX, y: barScaleY, anchor: .leading)
        .offset(x: barOffsetX)
        .opacity(barOpacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 6)

        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { appeared = true }
            if nowPlaying.isPlaying { triggerShow() }
        }
        .onChange(of: nowPlaying.isPlaying) { playing in
            playing ? triggerShow() : triggerHide()
        }
        .onChange(of: shouldRender) { show in
            if show { animateIn() } else { animateOut() }
        }
        .onChange(of: nowPlaying.artwork) { _ in refreshAccentColor() }
        .onChange(of: nowPlaying.title)   { _ in refreshAccentColor() }
    }

    // MARK: - 물방울 튀어나오기 (오른쪽으로 밀려나오며 뽈롱)
    private func animateIn() {
        HapticManager.shared.playNowBarAppear()

        barOffsetX = -10
        barScaleX  = 0.05
        barScaleY  = 0.2
        barOpacity = 0

        withAnimation(.spring(response: 0.40, dampingFraction: 0.55)) {
            barOffsetX = 0
            barScaleX  = 1.0
            barScaleY  = 1.0
            barOpacity = 1
        }
    }

    // MARK: - 노치로 복귀 (왼쪽으로 쏙)
    private func animateOut() {
        HapticManager.shared.playNowBarDisappear()

        withAnimation(.spring(response: 0.22, dampingFraction: 0.90)) {
            barOffsetX = -10
            barScaleX  = 0.05
            barScaleY  = 0.2
            barOpacity = 0
        }
    }

    // MARK: - Show / Hide
    private func triggerShow() {
        hideWorkItem?.cancel()
        hideWorkItem  = nil
        isShowingBar  = true
        waveAnimating = true
        refreshAccentColor()

        // 아트워크가 늦게 도착하는 경우를 위해 1·2초 후 추가 갱신
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard self.isShowingBar else { return }
            self.refreshAccentColor()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard self.isShowingBar else { return }
            self.refreshAccentColor()
        }
    }

    private func triggerHide() {
        waveAnimating = false
        let work = DispatchWorkItem {
            isShowingBar = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                accentColor = .black
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    // MARK: - 대표 색 추출 + 텍스트 색 결정
    private func refreshAccentColor() {
        guard let artwork = nowPlaying.artwork else {
            withAnimation(.easeInOut(duration: 0.4)) {
                accentColor = .black
                fgColor     = .white
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let raw      = artwork.dominantColor()
            let darkened = raw.blended(withFraction: 0.22, of: .black) ?? raw

            // 배경 밝기(luminance) 계산 → 밝으면 검정 텍스트, 어두우면 흰색 텍스트
            let r = darkened.redComponent
            let g = darkened.greenComponent
            let b = darkened.blueComponent
            let luminance = 0.299 * r + 0.587 * g + 0.114 * b
            let fg: Color = luminance > 0.50 ? .black : .white

            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.5)) {
                    accentColor = Color(darkened)
                    fgColor     = fg
                }
            }
        }
    }
}

// MARK: - 뮤직 웨이브
struct MusicWaveView: View {
    var animating: Bool
    var color: Color = .white
    let heights: [CGFloat] = [0.45, 0.9, 0.6, 1.0, 0.7]
    let delays:  [Double]  = [0.0, 0.12, 0.22, 0.08, 0.18]

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color.opacity(0.85))
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
