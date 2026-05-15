import SwiftUI

// MARK: - 단일 알약 뷰
/// NowBarPlugin 하나를 콜랩스/확장 알약으로 렌더링합니다.
/// - 콜랩스: 캡슐 형태, 탭하면 확장
/// - 확장: RoundedRectangle, 플러그인이 제공하는 풀 컨텐츠
struct NowBarPillView: View {
    let plugin: AnyNowBarPlugin

    @ObservedObject private var manager = NowBarPluginManager.shared

    private let collapsedHeight: CGFloat = 28
    private let expandedWidth:   CGFloat = 320
    private let expandedHeight:  CGFloat = 116

    private var isExpanded: Bool { manager.expandedPluginID == plugin.id }

    var body: some View {
        Group {
            if isExpanded {
                expandedPill
                    .transition(.asymmetric(
                        // 왼쪽 위 고정, 오른쪽·아래로 펼쳐짐
                        insertion: .scale(scale: 0.12, anchor: .topLeading)
                                    .combined(with: .opacity),
                        // 닫힐 때 오른쪽·아래에서 왼쪽·위로 줄어듦
                        removal:   .scale(scale: 0.12, anchor: .topLeading)
                                    .combined(with: .opacity)
                    ))
            } else {
                collapsedPill
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.75, anchor: .topLeading)
                                    .combined(with: .opacity),
                        removal:   .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.46, dampingFraction: 0.72), value: isExpanded)
    }

    // MARK: - 콜랩스 알약

    private var collapsedPill: some View {
        plugin.makeCollapsedView()
            .padding(.horizontal, 12)
            .frame(height: collapsedHeight)
            .background(Capsule().fill(plugin.accentColor))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                manager.expand(pluginID: plugin.id)
            }
    }

    // MARK: - 확장 알약

    private var expandedPill: some View {
        plugin.makeExpandedView()
            .frame(width: expandedWidth, height: expandedHeight)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: plugin.accentColor.opacity(0.45), radius: 5, x: 0, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .onTapGesture { /* 알약 본체 탭 흡수 — 바깥 탭은 SideBarContainerView에서 처리 */ }
    }
}
