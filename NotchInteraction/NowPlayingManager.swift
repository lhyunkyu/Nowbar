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
    /// 브라우저 position 보간용 — JS 폴 직후 기록, 0.5s 타이머에서 경과 시간만큼 더함
    private var lastBrowserPositionDate: Date? = nil

    // MARK: - 미디어 큐 (최근 재생 기록 → 소스 전환 시 이전 소스 복원)
    private struct MediaQueueItem {
        var source:      MusicSource
        var title:       String
        var artist:      String
        var artwork:     NSImage?
        var lastActiveAt: Date
    }
    private var mediaQueue: [MediaQueueItem] = []   // 최신순, 최대 3개

    private func enqueue(source: MusicSource, title: String, artist: String, artwork: NSImage?) {
        guard !title.isEmpty else { return }
        mediaQueue.removeAll { $0.source == source }
        mediaQueue.insert(MediaQueueItem(source: source, title: title, artist: artist,
                                         artwork: artwork, lastActiveAt: Date()), at: 0)
        if mediaQueue.count > 3 { mediaQueue.removeLast() }
    }

    /// 현재 소스가 멈춘 뒤 가장 최근 다른 소스로 복원 시도
    private func tryRestoreFromQueue(stoppedSource: MusicSource) {
        guard let next = mediaQueue.first(where: {
            $0.source != stoppedSource &&
            Date().timeIntervalSince($0.lastActiveAt) < 1800   // 30분 이내
        }) else { return }

        if next.source == .browser {
            // native lock 이 풀리는 시점 직후에 체크
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, self.source == .none else { return }
                self.checkBrowserMedia()
            }
        }
        // Spotify / Music은 DistributedNotification 이 스스로 처리
    }
    /// Spotify / Apple Music 이 현재 활성 재생 중 → 브라우저가 덮어쓰지 못하게 막음
    private var nativeAppIsActive: Bool = false
    /// Spotify 트랙 전환 시 Stopped→Playing 알림 사이에 브라우저가 끼어드는 것을 방지
    private var nativeLockUntil: Date? = nil
    private var isNativeLocked: Bool {
        guard let t = nativeLockUntil else { return false }
        return Date() < t
    }
    private func lockNative(for seconds: Double = 6) {
        nativeLockUntil = Date().addingTimeInterval(seconds)
    }

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
            registerForPlaying?(DispatchQueue.main)   // ← 즉시 등록 (이걸 해야 getNowPlayingInfo가 Chrome 포함 모든 앱 데이터를 줌)
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
        // Chrome 계열: JS 인젝션으로 video.paused / currentTime / duration 직접 읽기
        func chromeScript(appName: String) -> String { """
            tell application "\(appName)"
                set playingTab to missing value
                repeat with w in windows
                    repeat with t in tabs of w
                        if title of t starts with "▶" then
                            set playingTab to t
                            exit repeat
                        end if
                    end repeat
                    if playingTab is not missing value then exit repeat
                end repeat
                if playingTab is missing value then
                    repeat with w in windows
                        repeat with t in tabs of w
                            set u to URL of t
                            if u contains "youtube.com/watch" or u contains "music.youtube.com" or u contains "open.spotify.com/track" or u contains "soundcloud.com" then
                                set playingTab to t
                                exit repeat
                            end if
                        end repeat
                        if playingTab is not missing value then exit repeat
                    end repeat
                end if
                if playingTab is missing value then return ""
                set tabTitle to title of playingTab
                set tabURL to URL of playingTab
                try
                    set vState to execute playingTab javascript "var p=document.querySelector('.html5-video-player'),v=document.querySelector('video');p?(p.classList.contains('paused-mode')||p.classList.contains('ended-mode')?'0':'1')+'|'+(v?v.currentTime:0)+'|'+(v?v.duration:0):v?(v.paused?'0':'1')+'|'+v.currentTime+'|'+v.duration:''"
                on error
                    set vState to ""
                end try
                return tabTitle & "|||" & tabURL & "|||" & vState
            end tell
            """
        }
        // Safari: JS 실행 권한 제한으로 title+URL만 (position은 MediaRemote 보정)
        let safariScript = """
            tell application "Safari"
                set playingTab to missing value
                repeat with w in windows
                    repeat with t in tabs of w
                        if name of t starts with "▶" then
                            set playingTab to t
                            exit repeat
                        end if
                    end repeat
                    if playingTab is not missing value then exit repeat
                end repeat
                if playingTab is missing value then
                    repeat with w in windows
                        repeat with t in tabs of w
                            set u to URL of t
                            if u contains "youtube.com/watch" or u contains "music.youtube.com" or u contains "open.spotify.com/track" or u contains "soundcloud.com" then
                                set playingTab to t
                                exit repeat
                            end if
                        end repeat
                        if playingTab is not missing value then exit repeat
                    end repeat
                end if
                if playingTab is missing value then return ""
                return (name of playingTab) & "|||" & (URL of playingTab)
            end tell
            """
        return [
            ("com.google.Chrome",          "Google Chrome",  chromeScript(appName: "Google Chrome")),
            ("com.apple.Safari",           "Safari",         safariScript),
            ("com.brave.Browser",          "Brave Browser",  chromeScript(appName: "Brave Browser")),
            ("com.microsoft.edgemac",      "Microsoft Edge", chromeScript(appName: "Microsoft Edge")),
            ("company.thebrowser.Browser", "Arc",            chromeScript(appName: "Arc")),
        ]
    }

    // MARK: - 브라우저 미디어 감지 (앱 전환 즉시 + 2초 백업 폴링)
    private func registerMediaRemoteNotifications() {
        // MediaRemote 재생 상태 변경 알림 → 브라우저 source일 때 즉시 갱신
        // (registerForPlaying 호출 후 NotificationCenter.default 로 전달됨)
        let mrNames = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        ]
        for name in mrNames {
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name(name),
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, self.source == .browser else { return }
                self.fetchBrowserPositionMR()
            }
        }

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

        // 2초 백업 폴링 (브라우저 실행 중일 때만 실질 동작)
        browserTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkBrowserMedia()
        }
    }

    /// AppleScript로 브라우저 탭 정보 읽기
    func checkBrowserMedia() {
        // Spotify / Music 이 재생 중이거나 최근 알림이 왔으면 브라우저 감지 스킵
        guard !isNativeLocked else { return }
        let nativeStillRunning = NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.spotify.client" || $0.bundleIdentifier == "com.apple.Music"
        })
        guard !(nativeAppIsActive && nativeStillRunning) else { return }
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
            let parts      = raw.components(separatedBy: "|||")
            let tabTitle   = parts.first ?? raw
            let tabURL     = parts.count > 1 ? parts[1] : ""
            let videoState = parts.count > 2 ? parts[2] : ""
            DispatchQueue.main.async { self?.parseBrowserTitle(tabTitle, url: tabURL, videoState: videoState) }
        }
    }

    /// 탭 제목에서 곡명/아티스트 파싱 (YouTube, YouTube Music, Spotify Web, SoundCloud)
    /// videoState: JS 인젝션 결과 "isPlaying|currentTime|duration" (초기 position 힌트용)
    private func parseBrowserTitle(_ tabTitle: String, url: String, videoState: String = "") {
        // JS 파싱 — position 초기값 힌트 (isPlaying은 MediaRemote가 처리)
        let vsParts    = videoState.components(separatedBy: "|")
        let jsTime:    Double? = vsParts.count >= 3 ? Double(vsParts[1]) : nil
        let jsDur:     Double? = vsParts.count >= 3 ? Double(vsParts[2]) : nil

        // YouTube / YouTube Music
        if tabTitle.contains("YouTube") {
            // isPlaying은 MediaRemote가 결정 — 현재 값 유지하며 MR 즉시 호출
            let playing = tabTitle.first == "▶" ? true : self.isPlaying

            var t = tabTitle
                .replacingOccurrences(of: "▶ ", with: "")
                .replacingOccurrences(of: " - YouTube Music", with: "")
                .replacingOccurrences(of: " - YouTube", with: "")
            if t == "YouTube" || t == "YouTube Music" {
                if source == .browser { resetBrowserState() }; return
            }
            let changed = updateBrowserState(title: t, artist: "YouTube", isPlaying: playing)
            applyJSVideoState(jsTime: jsTime, jsDur: jsDur, needsMR: true)
            if changed { fetchYouTubeThumbnail(from: url) }
            enqueue(source: .browser, title: t, artist: "YouTube", artwork: artwork)
            return
        }

        // Spotify Web: "곡명 - 아티스트 • Spotify"
        if tabTitle.contains("• Spotify") {
            let cleaned = tabTitle.replacingOccurrences(of: " • Spotify", with: "")
            guard cleaned != "Spotify", !cleaned.isEmpty else {
                if source == .browser { resetBrowserState() }; return
            }
            let parts   = cleaned.components(separatedBy: " - ")
            let song    = parts.first ?? cleaned
            let artist  = parts.count > 1 ? parts[1] : "Spotify"
            let changed = updateBrowserState(title: song, artist: artist, isPlaying: self.isPlaying)
            applyJSVideoState(jsTime: jsTime, jsDur: jsDur, needsMR: true)
            if changed, let trackID = extractSpotifyTrackID(from: url) {
                fetchSpotifyArtwork(trackID: trackID)
            }
            enqueue(source: .browser, title: song, artist: artist, artwork: artwork)
            return
        }

        // SoundCloud: "♫ 곡명 by 아티스트 | SoundCloud"
        if tabTitle.contains("SoundCloud") {
            var t = tabTitle.replacingOccurrences(of: "♫ ", with: "")
            t = t.components(separatedBy: " | SoundCloud").first ?? t
            let parts  = t.components(separatedBy: " by ")
            let song   = parts.first ?? t
            let artist = parts.count > 1 ? parts[1] : "SoundCloud"
            _ = updateBrowserState(title: song, artist: artist, isPlaying: self.isPlaying)
            applyJSVideoState(jsTime: jsTime, jsDur: jsDur, needsMR: true)
            enqueue(source: .browser, title: song, artist: artist, artwork: artwork)
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

    /// JS position/duration 힌트 적용 후 MediaRemote로 정확한 상태 즉시 갱신
    private func applyJSVideoState(jsTime: Double?, jsDur: Double?, needsMR: Bool) {
        // JS 값은 초기 힌트용 — 이후 MediaRemote가 덮어씀
        if let ct = jsTime, ct.isFinite, ct >= 0 { position = ct }
        if let dur = jsDur, dur.isFinite, dur > 0 { duration = dur }
        // 항상 MR로 정확한 isPlaying + position 즉시 확인
        fetchBrowserPositionMR()
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
        isPlaying               = false
        title                   = ""
        artist                  = ""
        artwork                 = nil
        lastTrackID             = ""
        position                = 0
        duration                = 0
        lastBrowserPositionDate = nil
        source                  = .none
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

        // 브라우저에서 Spotify로 전환 시 브라우저 상태 클리어
        if !name.isEmpty && source == .browser { lastTrackID = "" }

        if self.title     != name   { self.title   = name }
        if self.artist    != art    { self.artist  = art }
        if self.isPlaying != playing { self.isPlaying = playing }
        if !name.isEmpty { self.source = .spotify }

        // Spotify duration: 노티에 ms로 들어옴
        if let durMs = info["Duration"] as? Double {
            self.duration = durMs / 1000.0
        }

        nativeAppIsActive = playing

        if stopped {
            lockNative(for: 1.5)
            nativeAppIsActive = false
            source            = .none
            tryRestoreFromQueue(stoppedSource: .spotify)
        } else {
            lockNative(for: 5)
            if trackID != lastTrackID {
                lastTrackID = trackID
                artwork     = nil
                position    = 0
                fetchSpotifyArtwork(trackID: trackID)
            }
            enqueue(source: .spotify, title: name, artist: art, artwork: artwork)
        }
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

        // 브라우저에서 Music으로 전환 시 브라우저 상태 클리어
        if !name.isEmpty && source == .browser { lastTrackID = "" }

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

        nativeAppIsActive = playing

        if stopped {
            lockNative(for: 1.5)
            nativeAppIsActive = false
            source            = .none
            tryRestoreFromQueue(stoppedSource: .music)
        } else {
            lockNative(for: 5)
            if trackID != lastTrackID {
                lastTrackID = trackID
                artwork     = nil
                position    = 0
                fetchArtworkAppleScript(app: "Music")
            }
            enqueue(source: .music, title: name, artist: art, artwork: artwork)
        }
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
        // 브라우저는 확장 직후 JS 폴로 정확한 position 확보
        if source == .browser { checkBrowserMedia() }
        fetchPositionOnce()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.fetchPositionOnce()
        }
    }

    func stopPositionPolling() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    /// MediaRemote를 통해 브라우저 재생 위치/길이 갱신
    private func fetchBrowserPositionMR() {
        guard let fn = getNowPlayingInfo else { return }
        fn(DispatchQueue.main) { [weak self] info in
            guard let self, self.source == .browser else { return }
            // 재생 속도 (0 = 일시정지, 1 = 재생)
            let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            self.isPlaying = rate > 0

            if let elapsed = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double {
                // 타임스탬프 기준으로 실제 위치 보정
                var pos = elapsed
                if rate > 0,
                   let ts = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
                    pos += Date().timeIntervalSince(ts) * rate
                }
                self.position = max(0, pos)
            }
            if let dur = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double, dur > 0 {
                self.duration = dur
            }
        }
    }

    private func fetchPositionOnce() {
        if source == .browser {
            // Chrome도 MediaRemote에 등록되어 있음 → 네이티브 앱과 동일하게 MR 사용
            fetchBrowserPositionMR()
            return
        }
        guard source != .none else { return }
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
