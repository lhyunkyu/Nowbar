import SwiftUI

// MARK: - 실시간 나우바 (레거시 진입점)
/// AppDelegate는 이 뷰를 NSHostingView에 담습니다.
/// 실제 렌더링은 SideBarContainerView → NowBarPillView → (각 플러그인) 구조로 위임됩니다.
///
/// 새 플러그인을 추가하려면:
/// 1. NowBarPluginProtocol을 채택하는 클래스를 만듭니다.
/// 2. AppDelegate.applicationDidFinishLaunching 에서
///    `NowBarPluginManager.shared.register(YourPlugin.shared)` 를 호출합니다.
/// 3. Xcode에서 새 파일을 "Add Files to NotchInteraction..." 으로 추가합니다.
struct SideBarNowPlayingView: View {
    var body: some View {
        SideBarContainerView()
    }
}
