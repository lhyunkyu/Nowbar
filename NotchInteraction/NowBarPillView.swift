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
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: isExpanded)
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
            .shadow(color: plugin.accentColor.opacity(0.7), radius: 8, x: 0, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .onTapGesture { /* 알약 본체 탭 흡수 — 바깥 탭은 SideBarContainerView에서 처리 */ }
    }
}
