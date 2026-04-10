import SwiftUI

struct SideBarNowPlayingView: View {
    @ObservedObject var state      = NotchState.shared
    @ObservedObject var nowPlaying = NowPlayingManager.shared

    var shouldShow: Bool {
        nowPlaying.isPlaying &&
        !nowPlaying.title.isEmpty &&
        state.proximity <= 0.08 &&
        !state.isExpanded &&
        !AlertWindowManager.shared.isVisible
    }

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 7) {
            if let artwork = nowPlaying.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 22, height: 22)
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            Text(nowPlaying.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 110, alignment: .leading)

            MusicWaveView()
                .frame(width: 14, height: 12)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            Capsule()
                .fill(Color.black)
                .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 3)
        )
        .offset(x: appeared && shouldShow ? 0 : -30)
        .opacity(appeared && shouldShow ? 1 : 0)
        .scaleEffect(
            x: appeared && shouldShow ? 1 : 0.5,
            y: appeared && shouldShow ? 1 : 0.85,
            anchor: .leading
        )
        .animation(
            shouldShow
                ? .spring(response: 0.38, dampingFraction: 0.58)
                : .spring(response: 0.25, dampingFraction: 0.8),
            value: shouldShow
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 6)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                appeared = true
            }
        }
    }
}

struct MusicWaveView: View {
    @State private var animating = false

    let heights: [CGFloat] = [0.45, 0.9, 0.6, 1.0, 0.7]
    let delays:  [Double]  = [0.0, 0.12, 0.22, 0.08, 0.18]

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.green.opacity(0.9))
                    .frame(width: 2, height: animating ? 12 * heights[i] : 2)
                    .animation(
                        .easeInOut(duration: 0.42)
                         .repeatForever(autoreverses: true)
                         .delay(delays[i]),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
