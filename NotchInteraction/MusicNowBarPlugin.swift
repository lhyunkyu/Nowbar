import SwiftUI
import Combine

// MARK: - Music NowBar Plugin
/// Spotify / Apple Music / Browser 재생 정보를 NowBar 알약으로 표시하는 플러그인.
/// 기존 SideBarNowPlayingView의 isActive / accentColor / fgColor 로직을 담당합니다.
final class MusicNowBarPlugin: ObservableObject, NowBarPluginProtocol {
    static let shared = MusicNowBarPlugin()

    let pluginID: String = "com.nowbar.music"
    let priority: Int    = 100

    @Published private(set) var isActive:    Bool  = false
    @Published private(set) var accentColor: Color = .black
    @Published private(set) var fgColor:     Color = .white
    /// 파형 리셋 ID — 알약 축소 시 증가시켜 MusicWaveView를 중립 상태로 리셋합니다.
    @Published private(set) var waveResetID: Int   = 0

    private var nowPlaying: NowPlayingManager { .shared }
    private var cancellables = Set<AnyCancellable>()
    private var hideWorkItem: DispatchWorkItem?

    private init() {
        setupObservers()
        if nowPlaying.isPlaying { triggerShow() }
    }

    // MARK: - Observers

    private func setupObservers() {
        nowPlaying.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                playing ? self?.triggerShow() : self?.triggerHide()
            }
            .store(in: &cancellables)

        nowPlaying.$source
            .receive(on: DispatchQueue.main)
            .sink { [weak self] src in
                guard let self else { return }
                if src == .browser && self.nowPlaying.isPlaying && !self.nowPlaying.title.isEmpty {
                    self.triggerShow()
                }
            }
            .store(in: &cancellables)

        nowPlaying.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                guard let self else { return }
                if !title.isEmpty && self.nowPlaying.source == .browser
                    && self.nowPlaying.isPlaying && !self.isActive {
                    self.triggerShow()
                }
            }
            .store(in: &cancellables)

        nowPlaying.$artwork
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAccentColor() }
            .store(in: &cancellables)
    }

    // MARK: - Show / Hide

    func triggerShow() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isActive = true
        refreshAccentColor()
        // 아트워크 로드 후 색상 재추출 (1초, 2.5초 지연)
        [1.0, 2.5].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.isActive == true else { return }
                self?.refreshAccentColor()
            }
        }
    }

    func triggerHide() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isActive = false
            NowBarPluginManager.shared.collapse(pluginID: self.pluginID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeInOut(duration: 0.4)) {
                    self.accentColor = .black
                    self.fgColor     = .white
                }
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    // MARK: - NowBarPluginProtocol

    func onExpand() {
        HapticManager.shared.playNowBarAppear()
        nowPlaying.startPositionPolling()
    }

    func onCollapse() {
        HapticManager.shared.playNowBarDisappear()
        nowPlaying.stopPositionPolling()
        waveResetID += 1
    }

    func makeCollapsedView() -> AnyView {
        AnyView(MusicCollapsedContent())
    }

    func makeExpandedView() -> AnyView {
        AnyView(MusicExpandedContent())
    }

    // MARK: - 대표색 추출

    private func refreshAccentColor() {
        guard let artwork = nowPlaying.artwork else {
            withAnimation(.easeInOut(duration: 0.4)) { accentColor = .black; fgColor = .white }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let raw      = artwork.dominantColor()
            let darkened = raw.blended(withFraction: 0.22, of: .black) ?? raw
            let lum = 0.299 * darkened.redComponent
                    + 0.587 * darkened.greenComponent
                    + 0.114 * darkened.blueComponent
            let fg: Color = lum > 0.50 ? .black : .white
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.5)) {
                    self?.accentColor = Color(darkened)
                    self?.fgColor     = fg
                }
            }
        }
    }
}

// MARK: - 콜랩스 컨텐츠 뷰
private struct MusicCollapsedContent: View {
    @ObservedObject private var plugin     = MusicNowBarPlugin.shared
    @ObservedObject private var nowPlaying = NowPlayingManager.shared

    var body: some View {
        HStack(spacing: 7) {
            FlippingArtworkView(
                artwork:             nowPlaying.artwork,
                size:                22,
                cornerRadius:        5,
                fgColor:             plugin.fgColor,
                placeholderIconSize: 10
            )
            TickerText(
                text:     nowPlaying.title.isEmpty ? "" : nowPlaying.title,
                maxWidth: 72,
                font:     .system(size: 11, weight: .semibold),
                color:    plugin.fgColor
            )
            MusicWaveView(animating: nowPlaying.isPlaying, color: plugin.fgColor)
                .frame(width: 14, height: 12)
                .id(plugin.waveResetID)
        }
    }
}

// MARK: - 확장 컨텐츠 뷰 (배경색 + 아트워크 블러 + 컨트롤)
private struct MusicExpandedContent: View {
    @ObservedObject private var plugin     = MusicNowBarPlugin.shared
    @ObservedObject private var nowPlaying = NowPlayingManager.shared

    var body: some View {
        ZStack {
            // 배경: accentColor + 아트워크 블러
            plugin.accentColor
            if let art = nowPlaying.artwork {
                Image(nsImage: art)
                    .resizable().scaledToFill()
                    .opacity(0.34).blur(radius: 10)
                    .allowsHitTesting(false)
            }
            // 컨트롤
            ExpandedNowBarContent(nowPlaying: nowPlaying, fgColor: plugin.fgColor)
        }
    }
}
