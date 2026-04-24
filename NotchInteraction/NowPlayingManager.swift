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

    // dlsym으로 읽어온 실제 상수 키 값
    private var artworkDataKey: String  = "kMRMediaRemoteNowPlayingInfoArtworkData"
    private var titleKey: String        = "kMRMediaRemoteNowPlayingInfoTitle"
    private var artistKey: String       = "kMRMediaRemoteNowPlayingInfoArtist"
    private var playbackRateKey: String = "kMRMediaRemoteNowPlayingInfoPlaybackRate"

    private init() {
        loadMediaRemote()
        registerAppNotifications()
        startPolling()
    }

    // MARK: - MediaRemote 로드
    private func loadMediaRemote() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

        // dlopen으로 프레임워크 로드 (상수 심볼 접근용)
        guard let handle = dlopen(path, RTLD_NOW) else {
            NSLog("❌ dlopen MediaRemote 실패")
            return
        }

        // 실제 상수 문자열 값을 dlsym으로 읽어옴
        func loadKey(_ symbol: String) -> String {
            if let ptr = dlsym(handle, symbol) {
                let cfStr = ptr.assumingMemoryBound(to: CFString.self).pointee
                return cfStr as String
            }
            return symbol   // fallback: 심볼명 그대로 사용
        }

        artworkDataKey  = loadKey("kMRMediaRemoteNowPlayingInfoArtworkData")
        titleKey        = loadKey("kMRMediaRemoteNowPlayingInfoTitle")
        artistKey       = loadKey("kMRMediaRemoteNowPlayingInfoArtist")
        playbackRateKey = loadKey("kMRMediaRemoteNowPlayingInfoPlaybackRate")

        NSLog("🔑 artworkDataKey  = \(artworkDataKey)")
        NSLog("🔑 titleKey        = \(titleKey)")
        NSLog("🔑 artistKey       = \(artistKey)")
        NSLog("🔑 playbackRateKey = \(playbackRateKey)")

        // CFBundle로 함수 포인터 로드
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        ) else { return }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            getNowPlayingInfo = unsafeBitCast(ptr, to: MRMediaRemoteGetNowPlayingInfoFunc.self)
            NSLog("✅ MRMediaRemoteGetNowPlayingInfo 로드")
        }

        if let ptr = CFBundleGetFunctionPointerForName(
            bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString
        ) {
            let register = unsafeBitCast(ptr, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunc.self)
            register(DispatchQueue.main)
            NSLog("✅ MRMediaRemoteRegisterForNowPlayingNotifications 등록")
        }

        let nc = NotificationCenter.default
        for name in [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        ] {
            nc.addObserver(self, selector: #selector(handleMediaRemoteNotification),
                           name: NSNotification.Name(name), object: nil)
        }
    }

    @objc private func handleMediaRemoteNotification(_ note: Notification) {
        NSLog("🔔 MediaRemote 알림: \(note.name.rawValue)")
        fetchFromMediaRemote()
    }

    // MARK: - 앱별 Distributed Notifications
    private func registerAppNotifications() {
        let dnc = DistributedNotificationCenter.default()
        let appNotifications: [(String, String)] = [
            ("com.spotify.client.PlaybackStateChanged", "handleSpotify:"),
            ("com.apple.Music.playerInfo",              "handleAppleMusic:"),
            ("com.apple.iTunes.playerInfo",             "handleAppleMusic:"),
            ("com.coppertino.Vox.trackChanged",         "handleGenericDNC:"),
            ("com.brushedtype.doppler.playbackState",   "handleGenericDNC:"),
        ]
        for (name, sel) in appNotifications {
            dnc.addObserver(self, selector: Selector(sel),
                            name: NSNotification.Name(name), object: nil)
        }
    }

    @objc private func handleSpotify(_ note: Notification) {
        let info  = note.userInfo ?? [:]
        let state = info["Player State"] as? String ?? ""
        let name  = info["Name"]         as? String ?? ""
        let art   = info["Artist"]       as? String ?? ""
        NSLog("🎵 [Spotify] \(state) – \(name)")
        applyState(title: name, artist: art, playing: state == "Playing" && !name.isEmpty)
    }

    @objc private func handleAppleMusic(_ note: Notification) {
        let info  = note.userInfo ?? [:]
        let state = info["Player State"] as? String ?? ""
        let name  = info["Name"]         as? String ?? ""
        let art   = info["Artist"]       as? String ?? ""
        NSLog("🎵 [Music] \(state) – \(name)")
        applyState(title: name, artist: art, playing: state == "Playing" && !name.isEmpty)
    }

    @objc private func handleGenericDNC(_ note: Notification) {
        NSLog("🔔 [Generic DNC] \(note.name.rawValue)")
        fetchFromMediaRemote()
    }

    // MARK: - MediaRemote fetch
    func fetchFromMediaRemote() {
        getNowPlayingInfo?(DispatchQueue.main) { [weak self] info in
            guard let self, !info.isEmpty else { return }

            // 항상 키 목록 로그 (아트워크 디버그용)
            NSLog("🔑 keys: \(info.keys.sorted())")

            let newTitle  = info[self.titleKey]  as? String ?? info["title"]  as? String ?? ""
            let newArtist = info[self.artistKey] as? String ?? info["artist"] as? String ?? ""

            let rate          = info[self.playbackRateKey] as? Double
            let isPlayingFlag = info["kMRMediaRemoteNowPlayingInfoIsPlaying"] as? Bool
            let playing: Bool
            if let flag = isPlayingFlag   { playing = flag && !newTitle.isEmpty }
            else if let r = rate          { playing = r > 0 && !newTitle.isEmpty }
            else                          { playing = !newTitle.isEmpty }

            NSLog("🔄 [MediaRemote] \(playing ? "▶" : "■") \(newTitle)")

            self.applyState(title: newTitle, artist: newArtist, playing: playing)

            // 아트워크: 실제 키 사용 + NSData 폴백
            let artData = info[self.artworkDataKey] as? Data
                       ?? (info[self.artworkDataKey] as? NSData).map { Data($0) }
                       ?? info["artworkData"] as? Data

            if let data = artData, !data.isEmpty, let img = NSImage(data: data) {
                NSLog("🖼️ 아트워크 수신 (\(data.count) bytes)")
                self.artwork = img
            } else {
                NSLog("🖼️ 아트워크 없음 (artworkDataKey=\(self.artworkDataKey))")
                if !playing { self.artwork = nil }
            }
        }
    }

    // MARK: - 상태 적용
    private func applyState(title newTitle: String, artist newArtist: String, playing newPlaying: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.title     != newTitle   { self.title   = newTitle }
            if self.artist    != newArtist  { self.artist  = newArtist }
            if self.isPlaying != newPlaying { self.isPlaying = newPlaying }

            if newPlaying { self.fetchArtworkWithRetry() }
            else          { self.artwork = nil }
        }
    }

    // MARK: - 아트워크 재시도 fetch
    private func fetchArtworkWithRetry(retries: Int = 5) {
        getNowPlayingInfo?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }

            let artData = info[self.artworkDataKey] as? Data
                       ?? (info[self.artworkDataKey] as? NSData).map { Data($0) }
                       ?? info["artworkData"] as? Data

            if let data = artData, !data.isEmpty, let img = NSImage(data: data) {
                NSLog("🖼️ 아트워크 재시도 성공 (\(data.count) bytes)")
                self.artwork = img
            } else if retries > 0 {
                NSLog("🖼️ 아트워크 재시도 \(retries)회 남음")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard self?.isPlaying == true else { return }
                    self?.fetchArtworkWithRetry(retries: retries - 1)
                }
            } else {
                NSLog("🖼️ 아트워크 최종 실패")
            }
        }
    }

    // MARK: - 폴링
    private func startPolling() {
        fetchFromMediaRemote()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.fetchFromMediaRemote()
        }
    }
}
