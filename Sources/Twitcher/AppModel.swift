import AVKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum Playback {
        case none
        case loading(TwitchTarget, message: String)
        case live(AVPlayer, login: String)
        case vod(AVPlayer, VodInfo)
        case failed(String)
    }

    enum DetailTab {
        case stream
        case broadcasts
    }

    @Published var channels: [ChannelInfo] = []
    @Published var selectedLogin: String?
    @Published var detailTab: DetailTab = .stream
    @Published var playback: Playback = .none
    @Published var showChat = true
    @Published private(set) var isRefreshing = false

    // MARK: - UI zoom

    private static let zoomKey = "uiZoom"
    private static let zoomRange = 0.6...2.2

    @Published var zoom: Double {
        didSet { UserDefaults.standard.set(zoom, forKey: Self.zoomKey) }
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.zoomKey)
        zoom = saved == 0 ? 1.0 : min(max(saved, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    func zoomIn() {
        zoom = min(zoom * 1.1, Self.zoomRange.upperBound)
    }

    func zoomOut() {
        zoom = max(zoom / 1.1, Self.zoomRange.lowerBound)
    }

    func resetZoom() {
        zoom = 1.0
    }

    let chat = ChatClient()
    let watchHistory = WatchProgressStore()
    private(set) var configPath: URL?
    private var playTask: Task<Void, Never>?
    private var progressObserver: Any?
    private var progressPlayer: AVPlayer?

    var selectedChannel: ChannelInfo? {
        channels.first { $0.login == selectedLogin }
    }

    // MARK: - Channel list

    func start() async {
        let (logins, path) = ChannelStore.load()
        configPath = path
        channels = logins.map {
            ChannelInfo(login: $0, displayName: $0, avatarURL: nil, live: nil, vods: [])
        }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing, !channels.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let logins = channels.map(\.login)
        await withTaskGroup(of: ChannelInfo?.self) { group in
            for login in logins {
                group.addTask { await TwitchAPI().fetchChannel(login: login) }
            }
            for await info in group {
                if let info, let index = channels.firstIndex(where: { $0.login == info.login }) {
                    channels[index] = info
                }
            }
        }
    }

    // MARK: - Navigation

    /// Called when the sidebar selection changes.
    func selectionChanged() {
        stopPlayback()
        guard let channel = selectedChannel else { return }
        detailTab = channel.live != nil ? .stream : .broadcasts
        applyTab()
    }

    /// Reconciles playback with the current tab. Idempotent, so it's safe to
    /// call from both selectionChanged() and the tab picker's onChange —
    /// whichever fires last is a no-op if the right thing is already playing.
    func applyTab() {
        guard let channel = selectedChannel else {
            stopPlayback()
            return
        }
        switch detailTab {
        case .stream:
            guard channel.live != nil else {
                stopPlayback()
                return
            }
            switch playback {
            case .live(_, let login) where login == channel.login:
                return
            case .loading(.live(let login), _) where login == channel.login:
                return
            default:
                playLive(channel)
            }
        case .broadcasts:
            switch playback {
            case .vod, .loading(.vod, _):
                return
            default:
                stopPlayback()
            }
        }
    }

    // MARK: - Playback

    func playLive(_ channel: ChannelInfo) {
        stopPlayback()
        playback = .loading(.live(channel: channel.login), message: "Loading \(channel.displayName)…")
        playTask = Task {
            do {
                let url = try await StreamResolver().resolve(.live(channel: channel.login))
                guard !Task.isCancelled else { return }
                let player = AVPlayer(url: url)
                player.play()
                playback = .live(player, login: channel.login)
                chat.connect(to: channel.login)
            } catch {
                guard !Task.isCancelled else { return }
                playback = .failed(error.localizedDescription)
            }
        }
    }

    func playVod(_ vod: VodInfo) {
        stopPlayback()
        playback = .loading(.vod(id: vod.id), message: "Loading VOD…")
        playTask = Task {
            do {
                let url = try await StreamResolver().resolve(.vod(id: vod.id))
                guard !Task.isCancelled else { return }
                let player = AVPlayer(url: url)

                // Resume partially watched VODs a few seconds before where
                // they left off; finished or barely-started ones restart.
                if let saved = watchHistory.progress(for: vod.id),
                   !saved.finished,
                   saved.position > 15,
                   saved.position < saved.duration - 30 {
                    _ = await player.seek(
                        to: CMTime(seconds: saved.position - 5, preferredTimescale: 600)
                    )
                    guard !Task.isCancelled else { return }
                }

                player.play()
                trackProgress(of: player, vod: vod)
                playback = .vod(player, vod)
            } catch {
                guard !Task.isCancelled else { return }
                playback = .failed(error.localizedDescription)
            }
        }
    }

    private func trackProgress(of player: AVPlayer, vod: VodInfo) {
        let duration = Double(vod.lengthSeconds)
        guard duration > 0 else { return }
        progressPlayer = player
        progressObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.watchHistory.update(vodID: vod.id, position: time.seconds, duration: duration)
            }
        }
    }

    /// Returns from VOD playback (or an error) to the channel overview.
    func closePlayback() {
        stopPlayback()
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        chat.disconnect()
        if let progressObserver, let progressPlayer {
            progressPlayer.removeTimeObserver(progressObserver)
        }
        progressObserver = nil
        progressPlayer = nil
        switch playback {
        case .live(let player, _):
            player.pause()
        case .vod(let player, let vod):
            watchHistory.update(
                vodID: vod.id,
                position: player.currentTime().seconds,
                duration: Double(vod.lengthSeconds)
            )
            player.pause()
        default: break
        }
        playback = .none
    }
}
