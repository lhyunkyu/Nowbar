import SwiftUI
import CoreImage

// MARK: - NSImage 대표 색상 추출
extension NSImage {
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
struct TextWidthKey: PreferenceKey {
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
    @State private var token: UUID        = UUID()

    private let gap: CGFloat = 32
    private var needsTicker: Bool { textWidth > maxWidth }
    private var loopWidth: CGFloat { textWidth + gap }
    private var duration: Double   { Double(loopWidth) / 35.0 }

    var body: some View {
        ZStack(alignment: .leading) {
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
        .onPreferenceChange(TextWidthKey.self) { width in
            guard abs(width - textWidth) > 0.5 else { return }
            textWidth = width
            restartTicker()
        }
    }

    private func restartTicker() {
        let newToken = UUID()
        token = newToken
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
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { offset = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                runLoop(token: token)
            }
        }
    }
}

// MARK: - 앨범아트 플립 애니메이션
struct FlippingArtworkView: View {
    let artwork: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat
    let fgColor: Color
    let placeholderIconSize: CGFloat

    @State private var displayed: NSImage? = nil
    @State private var rotation: Double    = 0

    var body: some View {
        Group {
            if let art = displayed {
                Image(nsImage: art)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(fgColor.opacity(0.2))
                        .frame(width: size, height: size)
                    Image(systemName: "music.note")
                        .font(.system(size: placeholderIconSize, weight: .medium))
                        .foregroundColor(fgColor.opacity(0.9))
                }
            }
        }
        .rotation3DEffect(.degrees(rotation), axis: (x: 0, y: 1, z: 0))
        .onAppear { displayed = artwork }
        .onChange(of: artwork) { newArtwork in
            withAnimation(.easeIn(duration: 0.16)) { rotation = 90 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                displayed = newArtwork
                rotation  = -90
                withAnimation(.easeOut(duration: 0.16)) { rotation = 0 }
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

    @State private var active: Bool = false

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color.opacity(0.85))
                    .frame(width: 2, height: active ? 12 * heights[i] : 2)
                    .animation(
                        active
                            ? .easeInOut(duration: 0.42).repeatForever(autoreverses: true).delay(delays[i])
                            : .easeInOut(duration: 0.25),
                        value: active
                    )
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { active = animating }
        }
        .onChange(of: animating) { active = $0 }
    }
}

// MARK: - 컨트롤 버튼 (호버 효과)
struct ControlButton: View {
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
