import Foundation
import AppKit
import CoreImage

class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()

    @Published var title: String     = ""
    @Published var artist: String    = ""
    @Published var isPlaying: Bool   = false
    @Published var artwork: NSImage? = nil

    // 마지막으로 업데이트한 소스 ("spotify" | "music" | "mediaremote")
    private var lastSource: String = ""

    private typealias MRMediaRemoteGetNowPlayingInfoFunc =
        @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private var getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFunc?

    private var pollingTimer: Timer?

    private init() {
        loadMediaRemote()
        registerDistributedNotifications()
        startPolling()
    }

    // MARK: - MediaRemote (아트워크 전용)
    private func loadMediaRemote() {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        ) else { NSLog("❌ MediaRemote 로드 실패"); return }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            getNowPlayingInfo = unsafeBitCast(ptr, to: MRMediaRemoteGetNowPlayingInfoFunc.self)
            NSLog("✅ MediaRemote 로드 성공")
        }
    }

    // MARK: - Distributed Notifications (Spotify / Apple Music 직접 수신)
    private func registerDistributedNotifications() {
        let dnc = DistributedNotificationCenter.default()

        // Spotify
        dnc.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleSpotify(note)
        }

        // Apple Music
        dnc.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleAppleMusic(note)
        }

        // iTunes (구버전 호환)
        dnc.addObserver(
            forName: NSNotification.Name("com.apple.iTunes.playerInfo"),
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleAppleMusic(note)
        }

        NSLog("✅ Distributed Notification 등록 완료")
    }

    private func handleSpotify(_ note: Notification) {
        let info  = note.userInfo ?? [:]
        let state = info["Player State"] as? String ?? ""
        let name  = info["Name"]   as? String ?? ""
        let art   = info["Artist"] as? String ?? ""

        NSLog("🎵 [Spotify] state=\(state) title=\(name) artist=\(art)")

        lastSource = "spotify"
        title      = name
        artist     = art
        isPlaying  = (state == "Playing") && !name.isEmpty

        // 아트워크는 MediaRemote에서 가져옴
        if isPlaying { fetchArtwork() }
        else         { artwork = nil }
    }

    private func handleAppleMusic(_ note: Notification) {
        let info  = note.userInfo ?? [:]
        let state = info["Player State"] as? String ?? ""
        let name  = info["Name"]   as? String ?? ""
        let art   = info["Artist"] as? String ?? ""

        NSLog("🎵 [Music] state=\(state) title=\(name) artist=\(art)")

        lastSource = "music"
        title      = name
        artist     = art
        isPlaying  = (state == "Playing") && !name.isEmpty

        if isPlaying { fetchArtwork() }
        else         { artwork = nil }
    }

    // MARK: - MediaRemote 아트워크 fetch
    private func fetchArtwork() {
        getNowPlayingInfo?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
                    ?? info["artworkData"] as? Data
            if let data, let img = NSImage(data: data) {
                self.artwork = img
                NSLog("🖼️ 아트워크 업데이트 성공")
            }
        }
    }

    // MARK: - 폴링 (Distributed Notification 못 받는 앱 대비 fallback)
    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollMediaRemote()
        }
    }

    private func pollMediaRemote() {
        getNowPlayingInfo?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            guard !info.isEmpty else { return }

            let newTitle = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String
                        ?? info["title"] as? String
                        ?? ""
            let newArtist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
                         ?? info["artist"] as? String
                         ?? ""
            let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double
                    ?? info["playbackRate"] as? Double
                    ?? 0.0
            let playing = rate > 0 && !newTitle.isEmpty

            // Distributed Notification 이미 받은 경우엔 title/artist 덮어쓰지 않음
            // 단, 아트워크는 항상 업데이트
            if self.lastSource == "" || newTitle != self.title {
                if self.title != newTitle   { self.title   = newTitle }
                if self.artist != newArtist { self.artist  = newArtist }
                if self.isPlaying != playing { self.isPlaying = playing }
                NSLog("🔄 [MediaRemote Polling] title=\(newTitle) playing=\(playing)")
            }

            let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
                    ?? info["artworkData"] as? Data
            if let data, let img = NSImage(data: data), self.artwork == nil {
                self.artwork = img
            }
        }
    }
}
