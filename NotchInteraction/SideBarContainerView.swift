import SwiftUI

// MARK: - 사이드바 플러그인 컨테이너
/// NowBarPluginManager에 등록된 활성 플러그인들을 세로로 쌓아서 표시합니다.
/// - isSideBarRendered: 노치 호버 여부에 따라 플러그인이 화면에 보이는지 추적
/// - shouldRender: 호버 중엔 숨기고 노치에서 멀어지면 다시 표시
struct SideBarContainerView: View {
    @ObservedObject private var manager    = NowBarPluginManager.shared
    @ObservedObject private var state      = NotchState.shared

    private let notchBarHeight:      CGFloat = 37
    private let collapsedPillHeight: CGFloat = 28
    private let pillSpacing:         CGFloat = 4

    /// 알약이 노치 영역에 보일 조건:
    /// - 활성 플러그인이 있고
    /// - 확장 중이거나, 노치 호버 중이 아닐 때
    private var shouldRender: Bool {
        !manager.activePlugins.isEmpty &&
        (manager.isAnyExpanded || (state.proximity <= 0.08 && !state.isExpanded))
    }

    /// 첫 번째 알약의 상단 여백
    private var topPadding: CGFloat {
        manager.isAnyExpanded ? 34 : (notchBarHeight - collapsedPillHeight) / 2
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 확장 상태에서 알약 바깥 탭 → 전체 축소
            if manager.isAnyExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { manager.collapseAll() }
            }

            if shouldRender {
                VStack(alignment: .leading, spacing: pillSpacing) {
                    ForEach(manager.activePlugins) { plugin in
                        NowBarPillView(plugin: plugin)
                    }
                }
                .padding(.leading, 6)
                .padding(.top, topPadding)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.05, anchor: .topLeading)
                                .combined(with: .opacity),
                    removal:   .scale(scale: 0.05, anchor: .topLeading)
                                .combined(with: .opacity)
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.40, dampingFraction: 0.55), value: shouldRender)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: manager.isAnyExpanded)
        .animation(.spring(response: 0.42, dampingFraction: 0.78),
                   value: manager.activePlugins.map(\.id))
        .onChange(of: shouldRender) { show in
            state.isSideBarRendered = show
            if show { HapticManager.shared.playNowBarAppear() }
            else     { HapticManager.shared.playNowBarDisappear() }
        }
        .onAppear {
            state.isSideBarRendered = shouldRender
        }
    }
}
