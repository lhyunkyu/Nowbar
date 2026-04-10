import SwiftUI

@main
struct NotchInteractionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 메인 윈도우 없이 백그라운드 앱으로 실행
        Settings {
            EmptyView()
        }
    }
}
