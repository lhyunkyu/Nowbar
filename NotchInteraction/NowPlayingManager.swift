import Foundation
import AppKit

class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()

    @Published var title: String     = ""
    @Published var artist: String    = ""
    @Published var isPlaying: Bool   = false
    @Published var artwork: NSImage? = nil

    private typealias MRMediaRemoteGetNowPlayingInfoFunc =
        @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private var getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFunc?
    private var pollingTimer: Timer?
    private var lastTrackID: String = ""   // 곡 변경 감지용

    private init() {
        loadMediaRemote()
        registerAppNotifications()
        startPolling()
    }

    // MARK: - MediaRemote (로드 시도, 실패해도 폴백 있음)
    private func loadMediaRemote() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else { return }
        if let ptr = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfo = unsafeBitCast(ptr, to: MRMediaRemoteGetNowPlayingInfoFunc.self)
            NSLog("✅ MediaRemote 함수 로드")
        }
    }

    // MARK: - Distributed Notifications 등록
    private func registerAppNotifications() {
        let dnc = DistributedNotificationCenter.default()

        dnc.addObserver(forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
                        object: nil, queue: .main) { [weak self] note in self?.handleSpotify(note) }

        dnc.addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"),
                        object: nil, queue: .main) { [weak self] note in self?.handleAppleMusic(note) }

        dnc.addObserver(forName: NSNotification.Name("com.apple.iTunes.playerInfo"),
                        object: nil, queue: .main) { [weak self] note in self?.handleAppleMusic(note) }

        NSLog("✅ Distributed Notification 등록 완료")
    }

    // MARK: - Spotify 핸들러
    private func handleSpotify(_ note: Notification) {
        let info  = note.userInfo ?? [:]
        let state = info["Player State"] as? String ?? ""
        let name  = info["Name"]         as? String ?? ""
        let art   = info["Artist"]       as? String ?? ""
        let trackID = info["Track ID"]   as? String ?? name

        NSLog("🎵 [Spotify] \(state) – \(name)")
        NSLog("🔑 [Spotify] 전체 키: \(info.keys.compactMap { $0 as? String }.sorted())")

        let playing = state == "Playing" && !name.isEmpty
        applyState(title: name, artist: art, playing: playing)

        if playing {
            if trackID != lastTrackID {
                lastTrackID = trackID
                // oEmbed API로 아트워크 URL 가져오기 (API 키 불필요)
                fetchSpotifyArtwork(trackID: trackID)
            }
        } else {
            artwork = nil
        }
    }

    // MARK: - Apple Music 핸들러
    private func handleAppleMusic(_ note: Notification) {
        let info  = note.userInfo ?? [:]
        let state = info["Player State"] as? String ?? ""
        let name  = info["Name"]         as? String ?? ""
        let art   = info["Artist"]       as? String ?? ""

        NSLog("🎵 [Music] \(state) – \(name)")

        let playing = state == "Playing" && !name.isEmpty
        applyState(title: name, artist: art, playing: playing)

        if playing {
            // Apple Music: AppleScript로 아트워크 직접 가져옴
            fetchArtworkAppleScript(app: "Music")
        } else {
            artwork = nil
        }
    }

    // MARK: - AppleScript 아트워크 (Apple Music 전용, 가장 확실한 방법)
    private func fetchArtworkAppleScript(app: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let src = """
            tell application "\(app)"
                try
                    if player state is playing then
                        set art to data of artwork 1 of current track
                        return art
                    end if
                end try
            end tell
            """
            guard let script = NSAppleScript(source: src) else { return }
            var err: NSDictionary?
            let result = script.executeAndReturnError(&err)

            if let e = err {
                NSLog("❌ AppleScript 오류: \(e)")
                return
            }
            // 결과가 raw data이면 NSImage로 변환
            let rawData = result.data
            if !rawData.isEmpty, let img = NSImage(data: rawData) {
                DispatchQueue.main.async {
                    NSLog("🖼️ AppleScript 아트워크 성공")
                    self?.artwork = img
                }
            } else {
                NSLog("⚠️ AppleScript 결과 타입: \(result.descriptorType)")
            }
        }
    }

    // MARK: - Spotify oEmbed API로 아트워크 가져오기 (API 키 불필요)
    private func fetchSpotifyArtwork(trackID: String) {
        // Track ID가 "spotify:track:XXXX" 형식이면 그대로, 아니면 uri로 감쌈
        let spotifyURI = trackID.hasPrefix("spotify:") ? trackID : "spotify:track:\(trackID)"
        guard let encoded = spotifyURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let oembedURL = URL(string: "https://open.spotify.com/oembed?url=\(encoded)") else { return }

        NSLog("🌐 Spotify oEmbed 요청: \(oembedURL)")
        URLSession.shared.dataTask(with: oembedURL) { [weak self] data, _, error in
            if let error { NSLog("❌ oEmbed 오류: \(error)"); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let thumbStr = json["thumbnail_url"] as? String,
                  let thumbURL = URL(string: thumbStr) else {
                NSLog("❌ oEmbed 파싱 실패")
                return
            }
            NSLog("🖼️ 아트워크 URL: \(thumbStr)")
            URLSession.shared.dataTask(with: thumbURL) { [weak self] imgData, _, _ in
                guard let imgData, let img = NSImage(data: imgData) else { return }
                DispatchQueue.main.async {
                    NSLog("🖼️ Spotify 아트워크 수신 성공")
                    self?.artwork = img
                }
            }.resume()
        }.resume()
    }

    // MARK: - URL에서 아트워크 다운로드 (범용)
    private func fetchArtworkFromURL(_ url: URL) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                NSLog("🖼️ URL 아트워크 성공: \(url)")
                self?.artwork = img
            }
        }.resume()
    }

    // MARK: - MediaRemote 아트워크 (폴백)
    private func fetchArtworkMediaRemote(retries: Int = 3) {
        getNowPlayingInfo?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
            if let data, !data.isEmpty, let img = NSImage(data: data) {
                NSLog("🖼️ MediaRemote 아트워크 성공 (\(data.count) bytes)")
                self.artwork = img
            } else if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard self?.isPlaying == true else { return }
                    self?.fetchArtworkMediaRemote(retries: retries - 1)
                }
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
            if !newPlaying { self.artwork = nil }
        }
    }

    // MARK: - 폴링 (Distributed Notification 누락 대비)
    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollAppleMusic()
        }
    }

    private func pollAppleMusic() {
        // AppleScript로 현재 재생 상태 체크 (Distributed Notification 못 받은 경우)
        DispatchQueue.global(qos: .background).async { [weak self] in
            let src = """
            tell application "Music"
                try
                    set s to player state as string
                    set n to name of current track
                    set a to artist of current track
                    return s & "||" & n & "||" & a
                end try
            end tell
            """
            guard let script = NSAppleScript(source: src) else { return }
            var err: NSDictionary?
            let result = script.executeAndReturnError(&err)
            guard err == nil, let str = result.stringValue else { return }

            let parts = str.components(separatedBy: "||")
            guard parts.count >= 3 else { return }
            let state  = parts[0]
            let name   = parts[1]
            let artist = parts[2]
            let playing = state == "playing" && !name.isEmpty

            DispatchQueue.main.async {
                self?.applyState(title: name, artist: artist, playing: playing)
                if playing && self?.artwork == nil {
                    self?.fetchArtworkAppleScript(app: "Music")
                }
            }
        }
    }
}
