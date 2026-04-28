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

// MARK: - 실시간 나우바 (콜랩스 + 확장 모드)
struct SideBarNowPlayingView: View {
    @ObservedObject var state      = NotchState.shared
    @ObservedObject var nowPlaying = NowPlayingManager.shared

    @State private var appeared:      Bool  = false
    @State private var isShowingBar:  Bool  = false
    @State private var waveAnimating: Bool  = false
    @State private var accentColor:   Color = .black
    @State private var fgColor:       Color = .white   // 배경 밝기에 따라 검정/흰색
    @State private var hideWorkItem:  DispatchWorkItem? = nil

    // 컨테이너 등장/사라짐 애니메이션
    @State private var barOffsetX:  CGFloat = -10
    @State private var barScaleX:   CGFloat = 0.05
    @State private var barScaleY:   CGFloat = 0.2
    @State private var barOpacity:  Double  = 0

    /// 노치 영역의 픽셀 높이 (윈도우 collapsed 높이와 동일)
    private let notchBarHeight: CGFloat = 37
    private let collapsedPillHeight: CGFloat = 28
    private let expandedPillWidth: CGFloat   = 320
    private let expandedPillHeight: CGFloat  = 96

    /// 알약 top 위치
    /// - 콜랩스: 노치 안에 수직 가운데
    /// - 확장: 알림센터 스타일로 노치보다 한참 아래 (약 50pt)
    private var topPadding: CGFloat {
        state.isSideBarExpanded ? 50 : (notchBarHeight - collapsedPillHeight) / 2
    }

    var shouldRender: Bool {
        isShowingBar &&
        !AlertWindowManager.shared.isVisible &&
        (state.isSideBarExpanded ||
         (state.proximity <= 0.08 && !state.isExpanded))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 확장 상태에서 알약 바깥(윈도우 라운드 코너 등 빈 영역) 탭 → 축소
            if state.isSideBarExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.isSideBarExpanded = false
                    }
            }

            Group {
                if state.isSideBarExpanded {
                    expandedPill
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.35, anchor: .topLeading).combined(with: .opacity),
                            removal:   .scale(scale: 0.35, anchor: .topLeading).combined(with: .opacity)
                        ))
                } else {
                    collapsedPill
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity),
                            removal:   .scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity)
                        ))
                }
            }
            .padding(.leading, 6)
            .padding(.top, topPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: state.isSideBarExpanded)

        // 컨테이너 전체의 등장/사라짐 (음악 재생 시작/종료 시)
        .scaleEffect(x: barScaleX, y: barScaleY, anchor: .topLeading)
        .offset(x: barOffsetX)
        .opacity(barOpacity)

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
        .onChange(of: state.isSideBarExpanded) { expanded in
            if expanded {
                HapticManager.shared.playNowBarAppear()
                nowPlaying.startPositionPolling()
            } else {
                HapticManager.shared.playNowBarDisappear()
                nowPlaying.stopPositionPolling()
            }
        }
    }

    // MARK: - 콜랩스(작은) 알약
    @ViewBuilder
    private var collapsedPill: some View {
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
        .frame(height: collapsedPillHeight)
        .background(Capsule().fill(accentColor))
        .contentShape(Capsule())
        .onTapGesture {
            // 클릭 → 확장
            state.isSideBarExpanded = true
        }
    }

    // MARK: - 확장(3배 큰) 알약
    @ViewBuilder
    private var expandedPill: some View {
        ExpandedNowBarContent(
            nowPlaying: nowPlaying,
            fgColor:    fgColor
        )
        .frame(width: expandedPillWidth, height: expandedPillHeight)
        .background(
            ZStack {
                // 베이스 — 앨범 대표색
                accentColor
                // 옅은 앨범아트 오버레이 (있을 때만) — 알약 전체에 흐릿하게 깔림
                if let art = nowPlaying.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .scaledToFill()
                        .opacity(0.32)
                        .blur(radius: 14)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            // 얕고 작은 그림자
            .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        // 알약 본체 탭은 흡수 (뒤의 Color.clear까지 떨어져 축소되지 않게)
        .onTapGesture { /* no-op */ }
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
            // 사라질 때 확장도 닫음
            if state.isSideBarExpanded { state.isSideBarExpanded = false }
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

// MARK: - 확장 알약 컨텐츠 (앨범아트 + 곡정보 + 진행바 + 컨트롤)
struct ExpandedNowBarContent: View {
    @ObservedObject var nowPlaying: NowPlayingManager
    var fgColor: Color

    @State private var isDragging: Bool   = false
    @State private var dragRatio:  Double = 0

    /// 시킹 가능 여부 (Spotify/Music 둘 다 지원, 곡 길이 알면 가능)
    private var canSeek: Bool {
        nowPlaying.duration > 0 && nowPlaying.source != .none
    }

    private var progress: Double {
        if isDragging { return dragRatio }
        guard nowPlaying.duration > 0 else { return 0 }
        return min(1.0, max(0, nowPlaying.position / nowPlaying.duration))
    }

    /// 드래그 중 시간 라벨에 표시할 위치
    private var displayedPosition: Double {
        if isDragging { return dragRatio * nowPlaying.duration }
        return nowPlaying.position
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 상단: 앨범 아트 + 제목/아티스트
            HStack(spacing: 10) {
                if let art = nowPlaying.artwork {
                    Image(nsImage: art)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(fgColor.opacity(0.18))
                        .frame(width: 30, height: 30)
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundColor(fgColor.opacity(0.7))
                        )
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(nowPlaying.title.isEmpty ? "재생 중인 음악 없음" : nowPlaying.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(fgColor)
                        .lineLimit(1).truncationMode(.tail)
                    Text(nowPlaying.artist.isEmpty ? " " : nowPlaying.artist)
                        .font(.system(size: 10))
                        .foregroundColor(fgColor.opacity(0.65))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }

            // 진행바 + 시간 (굵은 트랙 + 드래그 핸들)
            VStack(spacing: 1) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // 트랙
                        Capsule()
                            .fill(fgColor.opacity(0.22))
                            .frame(height: 6)
                            .frame(maxHeight: .infinity)
                        // 채움
                        Capsule()
                            .fill(fgColor.opacity(0.95))
                            .frame(width: max(0, geo.size.width * CGFloat(progress)), height: 6)
                            .frame(maxHeight: .infinity, alignment: .leading)
                        // 드래그 핸들 — 시킹 가능할 때만 표시
                        if canSeek {
                            Circle()
                                .fill(fgColor)
                                .frame(width: 11, height: 11)
                                .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                                .offset(x: max(0, geo.size.width * CGFloat(progress) - 5.5))
                                .scaleEffect(isDragging ? 1.18 : 1.0)
                                .animation(.easeOut(duration: 0.12), value: isDragging)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard canSeek, geo.size.width > 0 else { return }
                                isDragging = true
                                dragRatio  = max(0, min(1, value.location.x / geo.size.width))
                            }
                            .onEnded { value in
                                guard canSeek, geo.size.width > 0 else {
                                    isDragging = false; return
                                }
                                let r = max(0, min(1, value.location.x / geo.size.width))
                                dragRatio = r
                                nowPlaying.seek(to: r * nowPlaying.duration)
                                // 시킹 후 폴링 결과가 도착할 때까지 잠깐 드래그 상태 유지
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    isDragging = false
                                }
                            }
                    )
                }
                .frame(height: 12)  // 빡빡하게 — 6pt 트랙 + 11pt 핸들에 맞춤

                HStack {
                    Text(formatTime(displayedPosition))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(fgColor.opacity(0.55))
                        .monospacedDigit()
                    Spacer()
                    Text(formatTime(nowPlaying.duration))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(fgColor.opacity(0.55))
                        .monospacedDigit()
                }
            }

            // 컨트롤 버튼
            HStack(spacing: 0) {
                Spacer()
                ControlButton(systemName: "backward.fill", size: 13) {
                    nowPlaying.previousTrack()
                }
                .padding(.horizontal, 12)

                ControlButton(
                    systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                    size: 16
                ) {
                    nowPlaying.playPause()
                }
                .padding(.horizontal, 4)

                ControlButton(systemName: "forward.fill", size: 13) {
                    nowPlaying.nextTrack()
                }
                .padding(.horizontal, 12)
                Spacer()
            }
            .foregroundColor(fgColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 컨트롤 버튼 (호버 효과)
private struct ControlButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 4, height: size + 4)
                .contentShape(Rectangle())
                .opacity(hover ? 0.65 : 1.0)
                .scaleEffect(hover ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
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
