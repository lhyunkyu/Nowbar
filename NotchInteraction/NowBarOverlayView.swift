import SwiftUI

struct NowBarOverlayView: View {
    @ObservedObject var state      = NotchState.shared
    @ObservedObject var nowPlaying = NowPlayingManager.shared
    @ObservedObject var power      = PowerManager.shared

    @State private var currentTime: String   = ""
    @State private var dropProgress: CGFloat = 0.0
    @State private var offsetY: CGFloat      = -8
    @State private var wasShowing: Bool      = false

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var isHover: Bool    { state.proximity > 0.5 }
    var isExpanded: Bool { state.isExpanded }
    var shouldShow: Bool { isHover || isExpanded }

    var pillWidth: CGFloat    { isExpanded ? 480 : (nowPlaying.title.isEmpty ? 240 : 320) }
    var pillHeight: CGFloat   { isExpanded ? 120 : 44 }
    var cornerRadius: CGFloat { dropProgress * 22 }
    var contentOpacity: Double { Double(min(1.0, dropProgress * 1.8)) }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black)
                    .frame(width: pillWidth, height: pillHeight)
                    .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 8)
                    .animation(.spring(response: 0.38, dampingFraction: 0.65), value: pillWidth)
                    .animation(.spring(response: 0.38, dampingFraction: 0.65), value: pillHeight)

                Group {
                    if isExpanded {
                        ExpandedView(
                            nowPlaying: nowPlaying,
                            batteryLevel: power.batteryLevel,
                            currentTime: currentTime,
                            batteryIconName: batteryIconName,
                            batteryColor: batteryColor
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    } else {
                        MiniHoverView(
                            nowPlaying: nowPlaying,
                            batteryLevel: power.batteryLevel,
                            currentTime: currentTime,
                            batteryIconName: batteryIconName,
                            batteryColor: batteryColor
                        )
                        .padding(.horizontal, 14)
                    }
                }
                .opacity(contentOpacity)
                .frame(width: pillWidth, height: pillHeight)
                .clipped()
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.65), value: pillWidth)
            .animation(.spring(response: 0.38, dampingFraction: 0.65), value: pillHeight)
            .scaleEffect(x: dropProgress, y: dropProgress, anchor: .top)
            .offset(y: offsetY)
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: cornerRadius)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)  // AlertPopupView와 동일
        .onChange(of: shouldShow) { show in
            if show && !wasShowing {
                HapticManager.shared.playNowBarAppear()
                dropProgress = 0.0; offsetY = -8
                withAnimation(.spring(response: 0.38, dampingFraction: 0.58)) {
                    dropProgress = 1.0; offsetY = 10  // AlertPopupView와 동일
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.42)) {
                        offsetY = 6  // AlertPopupView와 동일
                    }
                }
            } else if !show && wasShowing {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    dropProgress = 0.0; offsetY = -8
                }
            }
            wasShowing = show
        }
        .onReceive(timer) { _ in
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            currentTime = f.string(from: Date())
        }
        .onAppear {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            currentTime = f.string(from: Date())
        }
    }

    func batteryIconName(_ level: Int) -> String {
        switch level {
        case 88...100: return "100"
        case 63...87:  return "75"
        case 38...62:  return "50"
        case 13...37:  return "25"
        default:       return "0"
        }
    }

    func batteryColor(_ level: Int) -> Color {
        level > 20 ? .green.opacity(0.9) : level > 10 ? .yellow : .red
    }
}

// MARK: - 확장 뷰

struct ExpandedView: View {
    let nowPlaying: NowPlayingManager
    let batteryLevel: Int
    let currentTime: String
    let batteryIconName: (Int) -> String
    let batteryColor: (Int) -> Color

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                if let artwork = nowPlaying.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 52, height: 52)
                        .overlay(Image(systemName: "music.note").font(.system(size: 20)).foregroundColor(.white.opacity(0.4)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(nowPlaying.title.isEmpty ? "재생 중인 음악 없음" : nowPlaying.title)
                        .font(.system(size: 14, weight: .bold)).foregroundColor(.white).lineLimit(1)
                    if !nowPlaying.artist.isEmpty {
                        Text(nowPlaying.artist)
                            .font(.system(size: 12)).foregroundColor(.white.opacity(0.55)).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: nowPlaying.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28)).foregroundColor(.white.opacity(0.85))
            }
            HStack {
                Image(systemName: "clock").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                Text(currentTime).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.7)).monospacedDigit()
                Spacer()
                Image(systemName: "battery.\(batteryIconName(batteryLevel))").font(.system(size: 12)).foregroundColor(batteryColor(batteryLevel))
                Text("\(batteryLevel)%").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.7))
            }
        }
    }
}

// MARK: - 호버 미니 뷰

struct MiniHoverView: View {
    let nowPlaying: NowPlayingManager
    let batteryLevel: Int
    let currentTime: String
    let batteryIconName: (Int) -> String
    let batteryColor: (Int) -> Color

    var body: some View {
        HStack(spacing: 10) {
            if let artwork = nowPlaying.artwork {
                Image(nsImage: artwork)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "clock").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.7))
            }
            if !nowPlaying.title.isEmpty {
                Text(nowPlaying.title)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: 160, alignment: .leading)
                Image(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
            } else {
                Text(currentTime)
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(.white).monospacedDigit()
            }
            Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 14)
            Image(systemName: "battery.\(batteryIconName(batteryLevel))")
                .font(.system(size: 12)).foregroundColor(batteryColor(batteryLevel))
        }
    }
}
