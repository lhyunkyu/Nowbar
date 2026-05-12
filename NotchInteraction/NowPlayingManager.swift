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
    private var browserTimer: Timer?
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
        guard let handle = dlopen(path, RTLD_NOW) else { return }

        if let ptr = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfo = unsafeBitCast(ptr, to: MRMediaRemoteGetNowPlayingInfoFunc.self)
        }

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

    // 음악 사이트 URL 패턴
    private let musicURLPatterns = ["youtube.com/watch", "youtube.com/shorts",
                                    "music.youtube.com", "open.spotify.com/track",
                                    "soundcloud.com"]

    // 지원 브라우저 (번들ID, 앱이름, AppleScript — 전체 탭 순회해서 재생 중인 탭 탐색)
    private var supportedBrowsers: [(bundleID: String, name: String, script: String)] {
        let musicPatterns = musicURLPatterns.joined(separator: "\", \"")
        // 1순위: ▶ 로 시작하는 탭 (YouTube 재생 중 표시)
        // 2순위: 음악 사이트 URL을 가진 탭
        let chromeScript = """
            tell application "Google Chrome"
                repeat with w in windows
                    repeat with t in tabs of w
                        if title of t starts with "▶" then
                            return (title of t) & "|||" & (URL of t)
                        end if
                    end repeat
                end repeat
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t
                        repeat with p in {"\(musicPatterns)"}
                            if u contains p then
                                return (title of t) & "|||" & u
                            end if
                        end repeat
                    end repeat
                end repeat
                return ""
            end tell
            """
        let safariScript = """
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        if name of t starts with "▶" then
                            return (name of t) & "|||" & (URL of t)
                        end if
                    end repeat
                end repeat
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t
                        repeat with p in {"\(musicPatterns)"}
                            if u contains p then
                                return (name of t) & "|||" & u
                            end if
                        end repeat
                    end repeat
                end repeat
                return ""
            end tell
            """
        return [
            ("com.google.Chrome",            "Google Chrome", chromeScript),
            ("com.apple.Safari",             "Safari",        safariScript),
            ("com.brave.Browser",            "Brave Browser", chromeScript.replacingOccurrences(of: "Google Chrome", with: "Brave Browser")),
            ("com.microsoft.edgemac",        "Microsoft Edge", chromeScript.replacingOccurrences(of: "Google Chrome", with: "Microsoft Edge")),
            ("company.thebrowser.Browser",   "Arc",           chromeScript.replacingOccurrences(of: "Google Chrome", with: "Arc")),
        ]
    }

    // MARK: - 브라우저 미디어 감지 (앱 전환 즉시 + 5초 백업 폴링)
    private func registerMediaRemoteNotifications() {
        // 브라우저로 전환 시 즉시 체크
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  self?.supportedBrowsers.contains(where: { $0.bundleID == bundleID }) == true
            else { return }
            self?.checkBrowserMedia()
        }

        // 5초 백업 폴링 (브라우저 실행 중일 때만 실질 동작)
        browserTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkBrowserMedia()
        }
    }

    /// AppleScript로 브라우저 탭 정보 읽기
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
            if err != nil { return }
            guard var raw = result.stringValue, !raw.isEmpty else {
                DispatchQueue.main.async { if self?.source == .browser { self?.resetBrowserState() } }
                return
            }
            // NSAppleScript가 긴 문자열에 "(160) " 같은 길이 접두사를 붙이는 경우 제거
            if raw.first == "(",
               let closeParen = raw.firstIndex(of: ")"),
               raw.distance(from: raw.startIndex, to: closeParen) < 10 {
                let afterSpace = raw.index(closeParen, offsetBy: 2, limitedBy: raw.endIndex) ?? raw.endIndex
                raw = String(raw[afterSpace...])
            }
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
            let isWatchPage = url.contains("youtube.com/watch") || url.contains("music.youtube.com")
            let playing = tabTitle.first == "▶" || isWatchPage
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
                .contains(where: { $0.bundleIdentifier == bundleID }) else { return }

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
                DispatchQueue.main.async { self?.artwork = img }
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
                  let thumbURL = URL(string: thumbStr) else { return }
            URLSession.shared.dataTask(with: thumbURL) { [weak self] imgData, _, _ in
                guard let imgData, let img = NSImage(data: imgData) else { return }
                DispatchQueue.main.async { self?.artwork = img }
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
