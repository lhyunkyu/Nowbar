import Foundation
import AppKit

/// 현재 재생 소스 — 컨트롤 명령을 어느 앱으로 보낼지 결정
enum MusicSource {
    case none
    case spotify
    case music
    case browser   // Chrome, Safari, Firefox, Arc 등
}

class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()

    @Published var title: String     = ""
    @Published var artist: String    = ""
    @Published var isPlaying: Bool   = false
    @Published var artwork: NSImage? = nil

    /// 현재 재생 중인 앱 (Spotify / Music) — 마지막으로 갱신된 소스를 기억
    @Published var source: MusicSource = .none

    /// 진행 위치 (초)
    @Published var position: Double = 0
    /// 곡 길이 (초)
    @Published var duration: Double = 0

    private typealias MRMediaRemoteGetNowPlayingInfoFunc =
        @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias MRMediaRemoteRegisterFunc =
        @convention(c) (DispatchQueue) -> Void
    private typealias MRMediaRemoteGetAppNameFunc =
        @convention(c) (DispatchQueue, @escaping (String?) -> Void) -> Void
    private typealias MRMediaRemoteSendCommandFunc =
        @convention(c) (UInt32, AnyObject?) -> Bool

    private var getNowPlayingInfo:   MRMediaRemoteGetNowPlayingInfoFunc?
    private var registerForPlaying:  MRMediaRemoteRegisterFunc?
    private var getAppDisplayName:   MRMediaRemoteGetAppNameFunc?
    private var mrSendCommand:       MRMediaRemoteSendCommandFunc?

    // MRMediaRemote 컨트롤 커맨드 상수
    private let kMRTogglePlayPause: UInt32 = 2
    private let kMRNextTrack:       UInt32 = 4
    private let kMRPreviousTrack:   UInt32 = 5

    // 브라우저 번들 ID 목록
    private let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",  // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera"
    ]

    private var pollingTimer: Timer?
    private var positionTimer: Timer?
    private var lastTrackID: String = ""

    private init() {
        loadMediaRemote()
        registerAppNotifications()
        registerMediaRemoteNotifications()
        startPolling()
    }

    // MARK: - MediaRemote 로드
    private func loadMediaRemote() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else {
            NSLog("❌ MediaRemote dlopen 실패")
            return
        }
        NSLog("✅ MediaRemote 로드 성공")

        if let ptr = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfo = unsafeBitCast(ptr, to: MRMediaRemoteGetNowPlayingInfoFunc.self)
            NSLog("✅ MRMediaRemoteGetNowPlayingInfo 로드됨")
        } else { NSLog("❌ MRMediaRemoteGetNowPlayingInfo 없음") }

        if let ptr = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            registerForPlaying = unsafeBitCast(ptr, to: MRMediaRemoteRegisterFunc.self)
        }
        if let ptr = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationDisplayName") {
            getAppDisplayName = unsafeBitCast(ptr, to: MRMediaRemoteGetAppNameFunc.self)
        }
        if let ptr = dlsym(handle, "MRMediaRemoteSendCommand") {
            mrSendCommand = unsafeBitCast(ptr, to: MRMediaRemoteSendCommandFunc.self)
        }
    }

    // 지원 브라우저 (번들ID, 앱이름, AppleScript — 제목|||URL 반환)
    private let supportedBrowsers: [(bundleID: String, name: String, script: String)] = [
        ("com.google.Chrome", "Google Chrome", """
         tell application "Google Chrome"
             set t to title of active tab of front window
             set u to URL of active tab of front window
             return t & "|||" & u
         end tell
         """),
        ("com.apple.Safari", "Safari", """
         tell application "Safari"
             set t to name of current tab of front window
             set u to URL of current tab of front window
             return t & "|||" & u
         end tell
         """),
        ("company.thebrowser.Browser", "Arc", """
         tell application "Arc"
             set t to title of active tab of front window
             set u to URL of active tab of front window
             return t & "|||" & u
         end tell
         """),
        ("com.brave.Browser", "Brave Browser", """
         tell application "Brave Browser"
             set t to title of active tab of front window
             set u to URL of active tab of front window
             return t & "|||" & u
         end tell
         """),
        ("com.microsoft.edgemac", "Microsoft Edge", """
         tell application "Microsoft Edge"
             set t to title of active tab of front window
             set u to URL of active tab of front window
             return t & "|||" & u
         end tell
         """),
    ]

    // MARK: - Darwin 알림으로 브라우저 미디어 변경 감지 (폴링 없음)
    private func registerMediaRemoteNotifications() {
        registerForPlaying?(DispatchQueue.main)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            selfPtr,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let manager = Unmanaged<NowPlayingManager>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { manager.checkBrowserMedia() }
            },
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification" as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// 브라우저 미디어 변경 시 호출 — AppleScript로 탭 정보 읽기
    func checkBrowserMedia() {
        guard source != .spotify && source != .music else { return }

        guard let browser = supportedBrowsers.first(where: { b in
            NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == b.bundleID })
        }) else {
            if source == .browser { resetBrowserState() }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let script = NSAppleScript(source: browser.script) else { return }
            var err: NSDictionary?
            let result = script.executeAndReturnError(&err)
            if let err = err { NSLog("❌ Browser AppleScript 에러: \(err)"); return }
            guard let raw = result.stringValue else { return }
            let parts    = raw.components(separatedBy: "|||")
            let tabTitle = parts.first ?? raw
            let tabURL   = parts.count > 1 ? parts[1] : ""
            DispatchQueue.main.async { self?.parseBrowserTitle(tabTitle, url: tabURL) }
        }
    }

    /// 탭 제목에서 곡명/아티스트 파싱 (YouTube, YouTube Music, Spotify Web, SoundCloud)
    private func parseBrowserTitle(_ tabTitle: String, url: String) {
        // YouTube / YouTube Music
        if tabTitle.contains("YouTube") {
            let playing = tabTitle.hasPrefix("▶")
            var t = tabTitle
                .replacingOccurrences(of: "▶ ", with: "")
                .replacingOccurrences(of: " - YouTube Music", with: "")
                .replacingOccurrences(of: " - YouTube", with: "")
            if t == "YouTube" || t == "YouTube Music" {
                if source == .browser { resetBrowserState() }; return
            }
            let changed = updateBrowserState(title: t, artist: "YouTube", isPlaying: playing)
            if changed { fetchYouTubeThumbnail(from: url) }
            return
        }

        // Spotify Web: "곡명 - 아티스트 • Spotify"
        if tabTitle.contains("• Spotify") {
            let cleaned = tabTitle.replacingOccurrences(of: " • Spotify", with: "")
            guard cleaned != "Spotify", !cleaned.isEmpty else {
                if source == .browser { resetBrowserState() }; return
            }
            let parts  = cleaned.components(separatedBy: " - ")
            let song   = parts.first ?? cleaned
            let artist = parts.count > 1 ? parts[1] : "Spotify"
            let changed = updateBrowserState(title: song, artist: artist, isPlaying: true)
            if changed, let trackID = extractSpotifyTrackID(from: url) {
                fetchSpotifyArtwork(trackID: trackID)
            }
            return
        }

        // SoundCloud: "♫ 곡명 by 아티스트 | SoundCloud"
        if tabTitle.contains("SoundCloud") {
            var t = tabTitle.replacingOccurrences(of: "♫ ", with: "")
            t = t.components(separatedBy: " | SoundCloud").first ?? t
            let parts  = t.components(separatedBy: " by ")
            let song   = parts.first ?? t
            let artist = parts.count > 1 ? parts[1] : "SoundCloud"
            _ = updateBrowserState(title: song, artist: artist, isPlaying: true)
            return
        }

        if source == .browser { resetBrowserState() }
    }

    /// 상태 업데이트 후 트랙 변경 여부 반환
    @discardableResult
    private func updateBrowserState(title: String, artist: String, isPlaying: Bool) -> Bool {
        let trackID = "\(title)-\(artist)"
        if self.title      != title    { self.title    = title }
        if self.artist     != artist   { self.artist   = artist }
        if self.isPlaying  != isPlaying { self.isPlaying = isPlaying }
        self.source = .browser
        guard trackID != lastTrackID else { return false }
        lastTrackID = trackID
        artwork     = nil
        return true
    }

    // MARK: - YouTube 썸네일 fetch
    private func fetchYouTubeThumbnail(from urlString: String) {
        guard let videoID = extractYouTubeVideoID(from: urlString) else { return }
        // hqdefault → maxresdefault 순으로 시도
        let thumbURL = "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg"
        guard let url = URL(string: thumbURL) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async { self?.artwork = img }
        }.resume()
    }

    private func extractYouTubeVideoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // youtube.com/watch?v=ID
        if let v = components.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        // youtu.be/ID
        if url.host == "youtu.be" { return url.pathComponents.dropFirst().first }
        return nil
    }

    // MARK: - Spotify Web 트랙 ID 추출
    private func extractSpotifyTrackID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              url.host?.contains("spotify.com") == true else { return nil }
        // open.spotify.com/track/ID
        let paths = url.pathComponents
        if let idx = paths.firstIndex(of: "track"), idx + 1 < paths.count {
            return paths[idx + 1]
        }
        return nil
    }

    private func resetBrowserState() {
        isPlaying   = false
        title       = ""
        artist      = ""
        artwork     = nil
        lastTrackID = ""
        source      = .none
    }

    private func isAnyBrowserRunning() -> Bool {
        supportedBrowsers.contains(where: { b in
            NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == b.bundleID })
        })
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
    }

    // MARK: - Spotify 핸들러
    private func handleSpotify(_ note: Notification) {
        let info    = note.userInfo ?? [:]
        let state   = info["Player State"] as? String ?? ""
        let name    = info["Name"]         as? String ?? ""
        let art     = info["Artist"]       as? String ?? ""
        let trackID = info["Track ID"]     as? String ?? name

        NSLog("🎵 [Spotify] \(state) – \(name)")

        let playing = state == "Playing" && !name.isEmpty
        let stopped = state == "Stopped" || name.isEmpty

        // isPlaying / title 업데이트
        if self.title     != name   { self.title   = name }
        if self.artist    != art    { self.artist  = art }
        if self.isPlaying != playing { self.isPlaying = playing }
        if !name.isEmpty { self.source = .spotify }

        // Spotify duration: 노티에 ms로 들어옴
        if let durMs = info["Duration"] as? Double {
            self.duration = durMs / 1000.0
        }

        if stopped {
            artwork     = nil
            lastTrackID = ""
            source      = .none   // 브라우저가 이어받을 수 있도록 소스 초기화
        } else if trackID != lastTrackID {
            // 곡이 바뀌었을 때만 아트워크 새로 가져오기
            lastTrackID = trackID
            artwork     = nil
            position    = 0
            fetchSpotifyArtwork(trackID: trackID)
        }
        // 일시정지(Paused)는 아트워크 유지
    }

    // MARK: - Apple Music 핸들러
    private func handleAppleMusic(_ note: Notification) {
        let info    = note.userInfo ?? [:]
        let state   = info["Player State"] as? String ?? ""
        let name    = info["Name"]         as? String ?? ""
        let art     = info["Artist"]       as? String ?? ""
        let trackID = "\(name)-\(art)"

        NSLog("🎵 [Music] \(state) – \(name)")

        let playing = state == "Playing" && !name.isEmpty
        let stopped = state == "Stopped" || name.isEmpty

        if self.title     != name   { self.title   = name }
        if self.artist    != art    { self.artist  = art }
        if self.isPlaying != playing { self.isPlaying = playing }
        if !name.isEmpty { self.source = .music }

        // Apple Music duration: 노티에 초 단위로 들어옴
        if let dur = info["Total Time"] as? Double {
            // Total Time은 ms로 들어오는 경우도 있어 보정
            self.duration = dur > 100000 ? dur / 1000.0 : dur
        } else if let dur = info["PlaybackDuration"] as? Double {
            self.duration = dur
        }

        if stopped {
            artwork     = nil
            lastTrackID = ""
            source      = .none   // 브라우저가 이어받을 수 있도록 소스 초기화
        } else if trackID != lastTrackID {
            // 곡이 바뀌었을 때만 아트워크 새로 가져오기
            lastTrackID = trackID
            artwork     = nil
            position    = 0
            fetchArtworkAppleScript(app: "Music")
        }
        // 일시정지(Paused)는 아트워크 유지
    }

    // MARK: - AppleScript 아트워크 (Apple Music 전용)
    private func fetchArtworkAppleScript(app: String) {
        // 해당 앱이 실행 중일 때만 실행 (앱 자동 실행 방지)
        let bundleID = app == "Music" ? "com.apple.Music" : "com.apple.iTunes"
        guard NSWorkspace.shared.runningApplications
                .contains(where: { $0.bundleIdentifier == bundleID }) else {
            NSLog("⚠️ \(app) 앱이 실행 중이 아님 — AppleScript 스킵")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let src = """
            tell application "\(app)"
                try
                    set art to data of artwork 1 of current track
                    return art
                end try
            end tell
            """
            guard let script = NSAppleScript(source: src) else { return }
            var err: NSDictionary?
            let result = script.executeAndReturnError(&err)
            if err != nil { return }

            let rawData = result.data
            if !rawData.isEmpty, let img = NSImage(data: rawData) {
                DispatchQueue.main.async {
                    NSLog("🖼️ AppleScript 아트워크 성공")
                    self?.artwork = img
                }
            }
        }
    }

    // MARK: - Spotify oEmbed API로 아트워크 가져오기
    private func fetchSpotifyArtwork(trackID: String) {
        let spotifyURI = trackID.hasPrefix("spotify:") ? trackID : "spotify:track:\(trackID)"
        guard let encoded = spotifyURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let oembedURL = URL(string: "https://open.spotify.com/oembed?url=\(encoded)") else { return }

        URLSession.shared.dataTask(with: oembedURL) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let thumbStr = json["thumbnail_url"] as? String,
                  let thumbURL = URL(string: thumbStr) else {
                NSLog("❌ Spotify oEmbed 파싱 실패")
                return
            }
            URLSession.shared.dataTask(with: thumbURL) { [weak self] imgData, _, _ in
                guard let imgData, let img = NSImage(data: imgData) else { return }
                DispatchQueue.main.async {
                    NSLog("🖼️ Spotify 아트워크 수신 성공")
                    self?.artwork = img
                }
            }.resume()
        }.resume()
    }

    // MARK: - 폴링 (Apple Music 실행 중일 때만, 앱 자동 실행 방지)
    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollIfNeeded()
        }
    }

    private func pollIfNeeded() {
        // Music 앱이 실제로 실행 중일 때만 폴링
        let musicRunning = NSWorkspace.shared.runningApplications
            .contains(where: { $0.bundleIdentifier == "com.apple.Music" })
        guard musicRunning else { return }

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

            let parts   = str.components(separatedBy: "||")
            guard parts.count >= 3 else { return }
            let state   = parts[0]
            let name    = parts[1]
            let artist  = parts[2]
            let playing = state == "playing" && !name.isEmpty
            let trackID = "\(name)-\(artist)"

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.title     != name   { self.title   = name }
                if self.artist    != artist { self.artist  = artist }
                if self.isPlaying != playing { self.isPlaying = playing }

                if playing && trackID != self.lastTrackID {
                    self.lastTrackID = trackID
                    self.artwork     = nil
                    self.position    = 0
                    self.fetchArtworkAppleScript(app: "Music")
                }
                if self.source == .none && playing { self.source = .music }
            }
        }
    }

    // MARK: - 재생 컨트롤
    private func runControl(_ command: String) {
        let appName: String
        switch source {
        case .spotify: appName = "Spotify"
        case .music:   appName = "Music"
        case .browser, .none: return
        }
        let bundleID = source == .spotify ? "com.spotify.client" : "com.apple.Music"
        guard NSWorkspace.shared.runningApplications
                .contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let src = "tell application \"\(appName)\" to \(command)"
            guard let script = NSAppleScript(source: src) else { return }
            var err: NSDictionary?
            _ = script.executeAndReturnError(&err)
        }
    }

    private func sendMRCommand(_ cmd: UInt32) {
        _ = mrSendCommand?(cmd, nil)
    }

    func playPause() {
        source == .browser ? sendMRCommand(kMRTogglePlayPause) : runControl("playpause")
    }
    func nextTrack() {
        source == .browser ? sendMRCommand(kMRNextTrack) : runControl("next track")
    }
    func previousTrack() {
        source == .browser ? sendMRCommand(kMRPreviousTrack) : runControl("previous track")
    }

    /// 진행 위치(초)를 직접 설정 — 진행바 시킹용
    func seek(to seconds: Double) {
        // 브라우저는 MediaRemote seek 미지원 — 시킹 스킵
        guard source != .browser else { return }
        let appName: String
        switch source {
        case .spotify: appName = "Spotify"
        case .music:   appName = "Music"
        case .none, .browser: return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let src = "tell application \"\(appName)\" to set player position to \(seconds)"
            guard let script = NSAppleScript(source: src) else { return }
            var err: NSDictionary?
            _ = script.executeAndReturnError(&err)
            if err == nil {
                DispatchQueue.main.async { self.position = seconds }
            }
        }
    }

    // MARK: - 진행도 폴링 (확장 모드에서만 사용)
    /// 0.5초 간격으로 player position을 갱신. 확장 시 호출.
    func startPositionPolling() {
        stopPositionPolling()
        fetchPositionOnce()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.fetchPositionOnce()
        }
    }

    func stopPositionPolling() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func fetchPositionOnce() {
        guard source != .none && source != .browser else { return }
        let appName  = source == .spotify ? "Spotify" : "Music"
        let bundleID = source == .spotify ? "com.spotify.client" : "com.apple.Music"
        guard NSWorkspace.shared.runningApplications
                .contains(where: { $0.bundleIdentifier == bundleID }) else { return }

        let isSpotify = source == .spotify
        DispatchQueue.global(qos: .background).async { [weak self] in
            let src = """
            tell application "\(appName)"
                try
                    set p to player position
                    set d to duration of current track
                    return (p as string) & "||" & (d as string)
                end try
            end tell
            """
            guard let script = NSAppleScript(source: src) else { return }
            var err: NSDictionary?
            let result = script.executeAndReturnError(&err)
            guard err == nil, let str = result.stringValue else { return }
            let parts = str.components(separatedBy: "||")
            guard parts.count == 2,
                  let p = Double(parts[0]),
                  let d = Double(parts[1]) else { return }
            // Spotify는 duration이 ms 단위
            let dur = isSpotify ? d / 1000.0 : d
            DispatchQueue.main.async {
                self?.position = p
                if dur > 0 { self?.duration = dur }
            }
        }
    }
}
