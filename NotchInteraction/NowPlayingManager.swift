import Foundation
import AppKit

class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()

    @Published var title: String    = ""
    @Published var artist: String   = ""
    @Published var isPlaying: Bool  = false
    @Published var artwork: NSImage? = nil

    private var pollingTimer: Timer?

    private typealias MRMediaRemoteGetNowPlayingInfoFunc      = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias MRMediaRemoteGetNowPlayingIsPlayingFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

    private var getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFunc?
    private var getIsPlaying: MRMediaRemoteGetNowPlayingIsPlayingFunc?

    private init() {
        loadFramework()
        startPolling()
    }

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
            NSLog("✅ MRMediaRemoteGetNowPlayingInfo 로드")
        }
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) {
            getIsPlaying = unsafeBitCast(ptr, to: MRMediaRemoteGetNowPlayingIsPlayingFunc.self)
            NSLog("✅ MRMediaRemoteGetNowPlayingApplicationIsPlaying 로드")
        }
    }

    private func startPolling() {
        fetch()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    func fetch() {
        getIsPlaying?(DispatchQueue.main) { [weak self] playing in
            self?.isPlaying = playing
        }

        getNowPlayingInfo?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }

            // 실제 키 덤프 (처음 한 번만)
            if self.title.isEmpty {
                NSLog("🔑 NowPlaying keys: \(info.keys.map { $0 })")
            }

            // macOS 에서 실제로 쓰이는 키 (문자열 그대로)
            self.title  = info["kMRMediaRemoteNowPlayingInfoTitle"]  as? String
                       ?? info["title"]                               as? String
                       ?? ""

            self.artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
                       ?? info["artist"]                              as? String
                       ?? ""

            // 아트워크
            let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
                           ?? info["artworkData"]                               as? Data
            if let data = artworkData {
                self.artwork = NSImage(data: data)
            } else {
                self.artwork = nil
            }

            NSLog("🎵 title=\(self.title) | artist=\(self.artist) | playing=\(self.isPlaying)")
        }
    }
}
