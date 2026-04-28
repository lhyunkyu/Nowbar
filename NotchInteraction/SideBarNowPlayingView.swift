import SwiftUI

// MARK: - 실시간 나우바 (콜랩스 + 확장 모드)
struct SideBarNowPlayingView: View {
    @ObservedObject var state      = NotchState.shared
    @ObservedObject var nowPlaying = NowPlayingManager.shared

    @State private var isShowingBar:  Bool  = false
    @State private var waveAnimating: Bool  = false
    @State private var accentColor:   Color = .black
    @State private var fgColor:       Color = .white
    @State private var hideWorkItem:  DispatchWorkItem? = nil
    @State private var waveResetID:   Int   = 0

    // 컨테이너 등장/사라짐 애니메이션 상태
    @State private var barOffsetX: CGFloat = -10
    @State private var barScaleX:  CGFloat = 0.05
    @State private var barScaleY:  CGFloat = 0.2
    @State private var barOpacity: Double  = 0

    private let notchBarHeight:      CGFloat = 37
    private let collapsedPillHeight: CGFloat = 28
    private let expandedPillWidth:   CGFloat = 320
    private let expandedPillHeight:  CGFloat = 116

    private var topPadding: CGFloat {
        state.isSideBarExpanded ? 34 : (notchBarHeight - collapsedPillHeight) / 2
    }

    var shouldRender: Bool {
        isShowingBar &&
        (state.isSideBarExpanded ||
         (state.proximity <= 0.08 && !state.isExpanded))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 확장 상태에서 알약 바깥 탭 → 축소
            if state.isSideBarExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { state.isSideBarExpanded = false }
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
        .scaleEffect(x: barScaleX, y: barScaleY, anchor: .topLeading)
        .offset(x: barOffsetX)
        .opacity(barOpacity)
        .onAppear {
            if nowPlaying.isPlaying { triggerShow() }
            state.isSideBarRendered = shouldRender
        }
        .onChange(of: nowPlaying.isPlaying)         { $0 ? triggerShow() : triggerHide() }
        .onChange(of: shouldRender)                 { show in
            state.isSideBarRendered = show
            show ? animateIn() : animateOut()
        }
        .onChange(of: nowPlaying.artwork)           { _ in refreshAccentColor() }
        .onChange(of: nowPlaying.title)             { _ in refreshAccentColor() }
        .onChange(of: state.isSideBarExpanded)      { onExpandedChanged($0) }
    }

    // MARK: - 콜랩스(작은) 알약
    @ViewBuilder
    private var collapsedPill: some View {
        HStack(spacing: 7) {
            FlippingArtworkView(
                artwork:             nowPlaying.artwork,
                size:                22,
                cornerRadius:        5,
                fgColor:             fgColor,
                placeholderIconSize: 10
            )
            TickerText(
                text:     nowPlaying.title.isEmpty ? "" : nowPlaying.title,
                maxWidth: 72,
                font:     .system(size: 11, weight: .semibold),
                color:    fgColor
            )
            MusicWaveView(animating: waveAnimating, color: fgColor)
                .frame(width: 14, height: 12)
                .id(waveResetID)
        }
        .padding(.horizontal, 12)
        .frame(height: collapsedPillHeight)
        .background(Capsule().fill(accentColor))
        .contentShape(Capsule())
        .onTapGesture { state.isSideBarExpanded = true }
    }

    // MARK: - 확장(큰) 알약
    @ViewBuilder
    private var expandedPill: some View {
        ExpandedNowBarContent(nowPlaying: nowPlaying, fgColor: fgColor)
            .frame(width: expandedPillWidth, height: expandedPillHeight)
            .background(
                ZStack {
                    accentColor
                    if let art = nowPlaying.artwork {
                        Image(nsImage: art)
                            .resizable().scaledToFill()
                            .opacity(0.34).blur(radius: 10)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: accentColor.opacity(0.7), radius: 8, x: 0, y: 4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .onTapGesture { /* no-op: 알약 본체 탭 흡수 */ }
    }

    // MARK: - 애니메이션
    private func animateIn() {
        HapticManager.shared.playNowBarAppear()
        barOffsetX = -10; barScaleX = 0.05; barScaleY = 0.2; barOpacity = 0
        withAnimation(.spring(response: 0.40, dampingFraction: 0.55)) {
            barOffsetX = 0; barScaleX = 1.0; barScaleY = 1.0; barOpacity = 1
        }
    }

    private func animateOut() {
        HapticManager.shared.playNowBarDisappear()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.90)) {
            barOffsetX = -10; barScaleX = 0.05; barScaleY = 0.2; barOpacity = 0
        }
    }

    // MARK: - Show / Hide
    private func triggerShow() {
        hideWorkItem?.cancel()
        hideWorkItem  = nil
        isShowingBar  = true
        waveAnimating = true
        refreshAccentColor()
        [1.0, 2.5].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.isShowingBar else { return }
                self.refreshAccentColor()
            }
        }
    }

    private func triggerHide() {
        waveAnimating = false
        let work = DispatchWorkItem {
            isShowingBar = false
            if state.isSideBarExpanded { state.isSideBarExpanded = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { accentColor = .black }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    private func onExpandedChanged(_ expanded: Bool) {
        if expanded {
            HapticManager.shared.playNowBarAppear()
            nowPlaying.startPositionPolling()
        } else {
            HapticManager.shared.playNowBarDisappear()
            nowPlaying.stopPositionPolling()
            waveResetID += 1
        }
    }

    // MARK: - 대표색 추출
    private func refreshAccentColor() {
        guard let artwork = nowPlaying.artwork else {
            withAnimation(.easeInOut(duration: 0.4)) { accentColor = .black; fgColor = .white }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let raw      = artwork.dominantColor()
            let darkened = raw.blended(withFraction: 0.22, of: .black) ?? raw
            let lum      = 0.299 * darkened.redComponent
                         + 0.587 * darkened.greenComponent
                         + 0.114 * darkened.blueComponent
            let fg: Color = lum > 0.50 ? .black : .white
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.5)) {
                    accentColor = Color(darkened)
                    fgColor     = fg
                }
            }
        }
    }
}
