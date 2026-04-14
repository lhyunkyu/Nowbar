import Foundation
import AppKit

class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()

    @Published var title: String     = ""
    @Published var artist: String    = ""
    @Published var isPlaying: Bool   = false
    @Published var artwork: NSImage? = nil

    private var pollingTimer: Timer?

    private typealias MRMediaRemoteGetNowPlayingInfoFunc = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private var getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFunc?

    private init() {
        loadFramework()
        registerNotifications()
        startPolling()
    }

    // MARK: - MediaRemote 프레임워크 로드
    private func loadFramework() {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        ) else {
            NSLog("❌ MediaRemote 로드 실패")
            return
        }
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            getNowPlayingInfo = unsafeBitCast(ptr, to: MRMediaRemoteGetNowPlayingInfoFunc.self)
            NSLog("✅ MRMediaRemoteGetNowPlayingInfo 로드 성공")
        } else {
            NSLog("❌ MRMediaRemoteGetNowPlayingInfo 로드 실패")
        }
    }

    // MARK: - 시스템 미디어 변경 알림 등록 (실시간 감지)
    private func registerNotifications() {
        // macOS가 미디어 정보가 바뀔 때 보내는 분산 알림
        let dnc = DistributedNotificationCenter.default()

        // Spotify
        dnc.addObserver(self, selector: #selector(mediaChanged),
                        name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)
        // Apple Music / iTunes
        dnc.addObserver(self, selector: #selector(mediaChanged),
                        name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil)
        dnc.addObserver(self, selector: #selector(mediaChanged),
                        name: NSNotification.Name("com.apple.iTunes.playerInfo"), object: nil)
        // 시스템 미디어 컨트롤 변경 (MediaRemote 자체 알림)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaChanged),
                        name: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaChanged),
                        name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"), object: nil)

        NSLog("✅ 미디어 알림 등록 완료")
    }

    @objc private func mediaChanged(_ notification: Notification) {
        NSLog("🔔 미디어 변경 알림: \(notification.name.rawValue)")
        fetch()
    }

    // MARK: - 폴링 (백업용, 1초마다)
    private func startPolling() {
        fetch()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    // MARK: - 현재 재생 정보 가져오기
    func fetch() {
        getNowPlayingInfo?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }

            // 처음 한 번만 키 덤프
            if self.title.isEmpty && !info.isEmpty {
                NSLog("🔑 NowPlaying keys: \(info.keys.sorted())")
            }

            // 제목
            let newTitle = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String
                        ?? info["title"] as? String
                        ?? ""

            // 아티스트
            let newArtist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
                         ?? info["artist"] as? String
                         ?? ""

            // 재생 상태: PlaybackRate > 0 이면 재생 중 (isPlaying 별도 함수보다 신뢰성 높음)
            let playbackRate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double
                            ?? info["playbackRate"] as? Double
                            ?? 0.0
            let newIsPlaying = playbackRate > 0 && !newTitle.isEmpty

            // 아트워크
            let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
                           ?? info["artworkData"] as? Data
            let newArtwork = artworkData.flatMap { NSImage(data: $0) }

            // 변경된 경우에만 업데이트 (불필요한 리렌더 방지)
            if self.title != newTitle     { self.title    = newTitle }
            if self.artist != newArtist   { self.artist   = newArtist }
            if self.isPlaying != newIsPlaying { self.isPlaying = newIsPlaying }

            // 아트워크는 데이터 기준으로 비교
            if newArtwork != nil && artworkData != nil {
                self.artwork = newArtwork
            } else if newArtwork == nil {
                self.artwork = nil
            }

            if !newTitle.isEmpty {
                NSLog("🎵 title=\(newTitle) | artist=\(newArtist) | playing=\(newIsPlaying) | rate=\(playbackRate)")
            }
        }
    }
}
