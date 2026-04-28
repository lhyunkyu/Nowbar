import SwiftUI

// MARK: - 확장 알약 컨텐츠 (앨범아트 + 곡정보 + 진행바 + 컨트롤)
struct ExpandedNowBarContent: View {
    @ObservedObject var nowPlaying: NowPlayingManager
    var fgColor: Color

    @State private var isDragging: Bool   = false
    @State private var dragRatio:  Double = 0

    private var canSeek: Bool {
        nowPlaying.duration > 0 && nowPlaying.source != .none
    }

    private var progress: Double {
        if isDragging { return dragRatio }
        guard nowPlaying.duration > 0 else { return 0 }
        return min(1.0, max(0, nowPlaying.position / nowPlaying.duration))
    }

    private var displayedPosition: Double {
        isDragging ? dragRatio * nowPlaying.duration : nowPlaying.position
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            trackInfoRow
            scrubberRow
            controlsRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - 상단: 앨범아트 + 제목/아티스트
    private var trackInfoRow: some View {
        HStack(spacing: 10) {
            FlippingArtworkView(
                artwork:             nowPlaying.artwork,
                size:                44,
                cornerRadius:        8,
                fgColor:             fgColor,
                placeholderIconSize: 18
            )
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
        .contentShape(Rectangle())
        .onTapGesture { openMusicApp(source: nowPlaying.source) }
    }

    // MARK: - 진행바 + 시간 라벨
    private var scrubberRow: some View {
        VStack(spacing: 1) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(fgColor.opacity(0.22))
                        .frame(height: 6).frame(maxHeight: .infinity)
                    Capsule()
                        .fill(fgColor.opacity(0.95))
                        .frame(width: max(0, geo.size.width * CGFloat(progress)), height: 6)
                        .frame(maxHeight: .infinity, alignment: .leading)
                    if canSeek {
                        Circle()
                            .fill(fgColor)
                            .frame(width: 11, height: 11)
                            .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                            .offset(x: max(0, geo.size.width * CGFloat(progress) - 5.5))
                            .opacity(isDragging ? 0 : 1)
                            .animation(.easeOut(duration: 0.12), value: isDragging)
                    }
                }
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: geo.size.width))
            }
            .frame(height: 12)

            HStack {
                Text(formatTime(displayedPosition))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(fgColor.opacity(0.55)).monospacedDigit()
                Spacer()
                Text(formatTime(nowPlaying.duration))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(fgColor.opacity(0.55)).monospacedDigit()
            }
        }
    }

    // MARK: - 재생 컨트롤
    private var controlsRow: some View {
        HStack(spacing: 0) {
            Spacer()
            ControlButton(systemName: "backward.fill", size: 13) { nowPlaying.previousTrack() }
                .padding(.horizontal, 12)
            ControlButton(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 16) {
                nowPlaying.playPause()
            }
            .padding(.horizontal, 4)
            ControlButton(systemName: "forward.fill", size: 13) { nowPlaying.nextTrack() }
                .padding(.horizontal, 12)
            Spacer()
        }
        .foregroundColor(fgColor)
    }

    // MARK: - Helpers
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard canSeek, width > 0 else { return }
                isDragging = true
                dragRatio  = max(0, min(1, value.location.x / width))
            }
            .onEnded { value in
                guard canSeek, width > 0 else { isDragging = false; return }
                let r = max(0, min(1, value.location.x / width))
                dragRatio = r
                nowPlaying.seek(to: r * nowPlaying.duration)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { isDragging = false }
            }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func openMusicApp(source: MusicSource) {
        switch source {
        case .spotify: NSWorkspace.shared.open(URL(string: "spotify:")!)
        case .music:   NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
        case .none:    break
        }
    }
}
