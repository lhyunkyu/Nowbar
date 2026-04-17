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

// MARK: - 실시간 나우바 (노치 옆 Live Now Bar)
struct SideBarNowPlayingView: View {
    @ObservedObject var state      = NotchState.shared
    @ObservedObject var nowPlaying = NowPlayingManager.shared

    /// 노래가 재생 중이고 노치 호버/확장 상태가 아닐 때만 표시
    var shouldShow: Bool {
        nowPlaying.isPlaying &&
        !nowPlaying.title.isEmpty &&
        state.proximity <= 0.08 &&
        !state.isExpanded &&
        !AlertWindowManager.shared.isVisible
    }

    @State private var appeared: Bool     = false
    @State private var accentColor: Color = Color.black

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

            // 노래 제목
            Text(nowPlaying.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 60, alignment: .leading)

            // 뮤직 웨이브
            MusicWaveView()
                .frame(width: 14, height: 12)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            Capsule()
                .fill(accentColor)
//                .shadow(color: accentColor.opacity(0.65), radius: 10, x: 0, y: 4)
        )
        // 노치에서 튀어나오는/들어가는 애니메이션
        // anchor: .leading → 왼쪽(노치 방향)에서 확장/수축
        .scaleEffect(
            x: appeared && shouldShow ? 1.0 : 0.05,
            y: appeared && shouldShow ? 1.0 : 0.6,
            anchor: .leading
        )
        .opacity(appeared && shouldShow ? 1 : 0)
        .animation(
            shouldShow
                ? .spring(response: 0.42, dampingFraction: 0.60)   // 튀어나올 때: 탄성 있게
                : .spring(response: 0.26, dampingFraction: 0.88),   // 들어갈 때: 빠르고 스냅하게
            value: shouldShow
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 6)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                appeared = true
            }
            refreshAccentColor()
        }
        .onChange(of: nowPlaying.artwork) { _ in
            refreshAccentColor()
        }
        .onChange(of: nowPlaying.isPlaying) { playing in
            if !playing {
                withAnimation(.easeInOut(duration: 0.4)) {
                    accentColor = .black
                }
            } else {
                refreshAccentColor()
            }
        }
    }

    // MARK: 대표 색 갱신 (백그라운드 스레드에서 추출 후 메인에서 업데이트)
    private func refreshAccentColor() {
        guard let artwork = nowPlaying.artwork else {
            withAnimation(.easeInOut(duration: 0.4)) { accentColor = .black }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let raw      = artwork.dominantColor()
            // 가독성을 위해 살짝 어둡게 블렌드
            let darkened = raw.blended(withFraction: 0.22, of: .black) ?? raw
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.5)) {
                    accentColor = Color(darkened)
                }
            }
        }
    }
}

// MARK: - 뮤직 웨이브 애니메이션
struct MusicWaveView: View {
    @State private var animating = false

    let heights: [CGFloat] = [0.45, 0.9, 0.6, 1.0, 0.7]
    let delays:  [Double]  = [0.0, 0.12, 0.22, 0.08, 0.18]

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.85))
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
