import Foundation
import AppKit

class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()

    @Published var title: String     = ""
    @Published var artist: String    = ""
    @Published var isPlaying: Bool   = false
    @Published var artwork: NSImage? = nil

    // MARK: - MediaRemote 함수 타입
    private typealias MRMediaRemoteGetNowPlayingInfoFunc =
        @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunc =
        @convention(c) (DispatchQueue) -> Void

    private var getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFunc?
    private var pollingTimer: Timer?

    private init() {
        loadMediaRemote()
        registerAppNotifications()
        startPolling()
    }

    // MARK: - MediaRemote 로드 + 시스템 미디어 알림 등록
    private func loadMediaRemote() {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        ) else { NSLog("❌ MediaRemote 로드 실패"); return }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            getNowPlayingInfo = unsafeBitCast(ptr, to: MRMediaRemoteGetNowPlayingInfoFunc.self)
            NSLog("✅ MRMediaRemoteGetNowPlayingInfo 로드")
        }

        // 시스템에 미디어 변경 알림 수신 등록
        // → Chrome, Safari, VLC, Podcasts 등 모든 플레이어 커버
        if let ptr = CFBundleGetFunctionPointerForName(
            bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString
        ) {
            let register = unsafeBitCast(ptr, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunc.self)
            register(DispatchQueue.main)
            NSLog("✅ MRMediaRemoteRegisterForNowPlayingNotifications 등록")
        }

        // MediaRemote가 올리는 NotificationCenter 알림 구독
        let nc = NotificationCenter.default
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        ]
        for name in names {
            nc.addObserver(self, selector: #selector(handleMediaRemoteNotification),
                           name: NSNotification.Name(name), object: nil)
        }
        NSLog("✅ MediaRemote 시스템 알림 구독 완료")
    }

    @objc private func handleMediaRemoteNotification(_ note: Notification) {
        NSLog("🔔 MediaRemote 알림: \(note.name.rawValue)")
        fetchFromMediaRemote()
    }

    // MARK: - 앱별 Distributed Notifications
    // Spotify, Apple Music 은 자체 알림을 바로 보내므로 더 빠르게 반응
    private func registerAppNotifications() {
        let dnc = DistributedNotificationCenter.default()

        let appNotifications: [(name: String, handler: String)] = [
            // Spotify
            ("com.spotify.client.PlaybackStateChanged", "handleSpotify:"),
            // Apple Music / iTunes
            ("com.apple.Music.playerInfo",              "handleAppleMusic:"),
            ("com.apple.iTunes.playerInfo",             "handleAppleMusic:"),
            // Vox
            ("com.coppertino.Vox.trackChanged",         "handleGenericDNC:"),
            // Doppler
            ("com.brushedtype.doppler.playbackState",   "handleGenericDNC:"),
        ]

        for (name, sel) in appNotifications {
            dnc.addObserver(self, selector: Selector(sel),
                            name: NSNotification.Name(name), object: nil)
        }
        NSLog("✅ 앱별 Distributed Notification 등록 완료")
    }

    // MARK: - Spotify 핸들러
    @objc private func handleSpotify(_ note: Notification) {
        let info  = note.userInfo ?? [:]
        let state = info["Player State"] as? String ?? ""
        let name  = info["Name"]         as? String ?? ""
        let art   = info["Artist"]       as? String ?? ""

        NSLog("🎵 [Spotify] \(state) – \(name)")
        applyState(title: name, artist: art, playing: state == "Playing" && !name.isEmpty)
    }

    // MARK: - Apple Music / iTunes 핸들러
    @objc private func handleAppleMusic(_ note: Notification) {
        let info  = note.userInfo ?? [:]
        let state = info["Player State"] as? String ?? ""
        let name  = info["Name"]         as? String ?? ""
        let art   = info["Artist"]       as? String ?? ""

        NSLog("🎵 [Music] \(state) – \(name)")
        applyState(title: name, artist: art, playing: state == "Playing" && !name.isEmpty)
    }

    // MARK: - 기타 앱 핸들러 (MediaRemote로 상세 정보 fetch)
    @objc private func handleGenericDNC(_ note: Notification) {
        NSLog("🔔 [Generic DNC] \(note.name.rawValue)")
        fetchFromMediaRemote()
    }

    // MARK: - MediaRemote fetch (Chrome·Safari·VLC·Podcasts 등 모든 플레이어)
    func fetchFromMediaRemote() {
        getNowPlayingInfo?(DispatchQueue.main) { [weak self] info in
            guard let self, !info.isEmpty else { return }

            let newTitle  = info["kMRMediaRemoteNowPlayingInfoTitle"]  as? String ?? ""
            let newArtist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let rate      = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0.0
            let playing   = rate > 0 && !newTitle.isEmpty

            NSLog("🔄 [MediaRemote] \(playing ? "▶" : "■") \(newTitle)")

            self.applyState(title: newTitle, artist: newArtist, playing: playing)

            // 아트워크
            if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
               let img  = NSImage(data: data) {
                self.artwork = img
            } else if !playing {
                self.artwork = nil
            }
        }
    }

    // MARK: - 상태 적용 (중복 업데이트 방지)
    private func applyState(title newTitle: String, artist newArtist: String, playing newPlaying: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.title     != newTitle   { self.title   = newTitle }
            if self.artist    != newArtist  { self.artist  = newArtist }
            if self.isPlaying != newPlaying { self.isPlaying = newPlaying }

            // 재생 시작 시 아트워크 fetch (Spotify·Music 알림엔 아트워크 없음)
            if newPlaying { self.fetchArtworkIfNeeded() }
            else          { self.artwork = nil }
        }
    }

    private func fetchArtworkIfNeeded() {
        getNowPlayingInfo?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
               let img  = NSImage(data: data) {
                self.artwork = img
            }
        }
    }

    // MARK: - 폴링 (알림 놓치는 경우 fallback, 2초마다)
    private func startPolling() {
        fetchFromMediaRemote()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fetchFromMediaRemote()
        }
    }
}
