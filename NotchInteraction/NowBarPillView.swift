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
        ZStack(alignment: .topLeading) {
            // 콜랩스 알약: 항상 계층에 존재, 확장 시 독립적으로 페이드아웃
            collapsedPill
                .opacity(isExpanded ? 0 : 1)
                .animation(.easeOut(duration: 0.14), value: isExpanded)

            // 확장 알약: 왼쪽 위에서 오른쪽·아래로 펼쳐지고, 닫힐 때 반대로
            if isExpanded {
                expandedPill
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.12, anchor: .topLeading)
                                    .combined(with: .opacity),
                        removal:   .scale(scale: 0.12, anchor: .topLeading)
                                    .combined(with: .opacity)
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
