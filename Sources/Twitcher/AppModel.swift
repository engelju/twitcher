import AVKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    /// How the current content is being played.
    enum PlayerBackend {
        case native(AVPlayer)
        /// YouTube embed web view — used when yt-dlp isn't available.
        case embed(youtubeVideoID: String)
    }

    /// What a .loading state is heading towards, so tab/selection changes
    /// can tell stream loads from VOD loads.
    enum LoadingIntent: Equatable {
        case stream(channelID: String)
        case vod(id: String)
    }

    enum Playback {
        case none
        case loading(LoadingIntent, message: String)
        case live(PlayerBackend, channelID: String)
        case vod(PlayerBackend, VodInfo)
        case failed(String)
    }

    enum DetailTab {
        case stream
        case broadcasts
    }

    @Published var channels: [ChannelInfo] = []
    @Published var selectedChannelID: String?
    @Published var detailTab: DetailTab = .stream
    @Published var playback: Playback = .none
    @Published var showChat = true
    @Published private(set) var isRefreshing = false

    /// Qualities offered by the current stream's master playlist; empty when
    /// playback isn't native or the source has only one rendition.
    @Published private(set) var qualities: [HLSVariant] = []
    /// nil means automatic (adaptive) selection.
    @Published private(set) var selectedQuality: HLSVariant?
    /// Set when a YouTube video could only be resolved at a single low
    /// quality, so the UI can explain why the picker is empty.
    @Published private(set) var qualityNote: String?

    // MARK: - UI zoom

    private static let zoomKey = "uiZoom"
    private static let zoomRange = 0.6...2.2
    private static let qualityKey = "preferredQualityHeight"

    @Published var zoom: Double {
        didSet { UserDefaults.standard.set(zoom, forKey: Self.zoomKey) }
    }

    /// Stored as a mode rather than a specific variant because every stream
    /// offers a different ladder.
    enum QualityPreference: Equatable {
        /// Always the highest rendition on offer.
        case best
        /// Let AVPlayer adapt to the connection.
        case auto
        /// A specific rendition height, matched as closely as the ladder allows.
        case height(Int)
    }

    @Published private(set) var preference: QualityPreference = .best {
        didSet { UserDefaults.standard.set(Self.encode(preference), forKey: Self.qualityKey) }
    }

    private static func encode(_ preference: QualityPreference) -> String {
        switch preference {
        case .best: return "best"
        case .auto: return "auto"
        case .height(let height): return "h\(height)"
        }
    }

    private static func decode(_ raw: String?) -> QualityPreference {
        switch raw {
        case "auto": return .auto
        case let value? where value.hasPrefix("h"):
            return Int(value.dropFirst()).map { .height($0) } ?? .best
        default: return .best
        }
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.zoomKey)
        zoom = saved == 0 ? 1.0 : min(max(saved, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        preference = Self.decode(UserDefaults.standard.string(forKey: Self.qualityKey))
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
    let chatReplay = ChatReplayClient()
    let watchHistory = WatchProgressStore()
    let youtubeAccount = YouTubeAccount()
    private(set) var configPath: URL?
    private var playTask: Task<Void, Never>?
    private var progressObserver: Any?
    private var chatSyncObserver: Any?
    private var observedPlayer: AVPlayer?
    private var progressContext: (vodID: String, duration: Double)?
    /// The adaptive master for the current stream, used when switching to
    /// `.auto` or between renditions.
    private var masterURL: URL?

    var selectedChannel: ChannelInfo? {
        channels.first { $0.id == selectedChannelID }
    }

    // MARK: - Channel list

    func start() async {
        let (entries, path) = ChannelStore.load()
        configPath = path
        channels = entries.map {
            ChannelInfo(
                platform: $0.platform, login: $0.name, displayName: $0.name,
                avatarURL: nil, live: nil, vods: []
            )
        }
        await youtubeAccount.checkSignIn()
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing, !channels.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let snapshot = channels
        await withTaskGroup(of: ChannelInfo?.self) { group in
            for channel in snapshot {
                group.addTask {
                    switch channel.platform {
                    case .twitch:
                        return await TwitchAPI().fetchChannel(login: channel.login)
                    case .youtube:
                        return await YouTubeAPI().fetchChannel(handle: channel.login)
                    }
                }
            }
            for await info in group {
                if let info, let index = channels.firstIndex(where: { $0.id == info.id }) {
                    channels[index] = info
                }
            }
        }
    }

    /// Whether a subscription already has a sidebar entry, matched by
    /// handle or channel ID (channels.json may use either).
    func isInSidebar(_ subscription: YouTubeSubscription) -> Bool {
        channels.contains { channel in
            guard channel.platform == .youtube else { return false }
            return channel.youtubeChannelID == subscription.channelID
                || channel.login == subscription.channelID
                || channel.login.lowercased() == subscription.handle?.lowercased()
        }
    }

    /// Adds a subscribed channel to the sidebar and channels.json, then
    /// selects it.
    func addYouTubeChannel(_ subscription: YouTubeSubscription) {
        guard !isInSidebar(subscription) else { return }
        let channel = ChannelInfo(
            platform: .youtube, login: subscription.identifier, displayName: subscription.title,
            avatarURL: subscription.avatarURL, live: nil, vods: [],
            youtubeChannelID: subscription.channelID
        )
        channels.append(channel)
        // On a write failure the channel still shows for this session.
        if let configPath {
            try? ChannelStore.addYouTube(subscription.identifier, to: configPath)
        }
        selectedChannelID = channel.id

        Task {
            guard let info = await YouTubeAPI().fetchChannel(handle: channel.login),
                  let index = channels.firstIndex(where: { $0.id == info.id })
            else { return }
            channels[index] = info
            // Selected before its live status was known; start the stream
            // now if it turns out to be live.
            if selectedChannelID == info.id, info.live != nil, case .none = playback {
                detailTab = .stream
            }
        }
    }

    /// Removes a channel from the sidebar and channels.json.
    func removeChannel(id: String) {
        guard let channel = channels.first(where: { $0.id == id }) else { return }
        if selectedChannelID == id {
            // Stops playback via selectionChanged().
            selectedChannelID = nil
        }
        channels.removeAll { $0.id == id }
        if let configPath {
            try? ChannelStore.remove(channel.platform, channel.login, from: configPath)
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
            case .live(_, let channelID) where channelID == channel.id:
                return
            case .loading(.stream(let channelID), _) where channelID == channel.id:
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
        playback = .loading(.stream(channelID: channel.id), message: "Loading \(channel.displayName)…")
        playTask = Task {
            do {
                switch channel.platform {
                case .twitch:
                    let master = try await StreamResolver().resolve(.live(channel: channel.login))
                    guard !Task.isCancelled else { return }
                    let url = await prepareQualities(masterURL: master)
                    guard !Task.isCancelled else { return }
                    let player = AVPlayer(url: url)
                    player.play()
                    playback = .live(.native(player), channelID: channel.id)
                    chat.connect(to: channel.login)

                case .youtube:
                    guard let videoID = channel.live?.videoID else {
                        playback = .failed("\(channel.displayName) is not live.")
                        return
                    }
                    let backend = await resolveYouTube(videoID: videoID)
                    guard !Task.isCancelled else { return }
                    playback = .live(backend.backend, channelID: channel.id)
                }
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
                switch vod.platform {
                case .twitch:
                    let master = try await StreamResolver().resolve(.vod(id: vod.id))
                    guard !Task.isCancelled else { return }
                    let url = await prepareQualities(masterURL: master)
                    guard !Task.isCancelled else { return }
                    let player = AVPlayer(url: url)
                    let startOffset = await resumeIfNeeded(player, vodID: vod.id)
                    guard !Task.isCancelled else { return }
                    player.play()
                    trackProgress(of: player, vodID: vod.id, duration: Double(vod.lengthSeconds))
                    chatReplay.start(videoID: vod.id, at: startOffset)
                    attachChatSync(to: player)
                    playback = .vod(.native(player), vod)

                case .youtube:
                    let resolved = await resolveYouTube(videoID: vod.id)
                    guard !Task.isCancelled else { return }
                    if case .native(let player) = resolved.backend {
                        _ = await resumeIfNeeded(player, vodID: vod.id)
                        guard !Task.isCancelled else { return }
                        player.play()
                        trackProgress(of: player, vodID: vod.id, duration: resolved.duration ?? 0)
                    }
                    playback = .vod(resolved.backend, vod)
                }
            } catch {
                guard !Task.isCancelled else { return }
                playback = .failed(error.localizedDescription)
            }
        }
    }

    /// yt-dlp when available (native player, tracked progress); the official
    /// embed player otherwise.
    private func resolveYouTube(videoID: String) async -> (backend: PlayerBackend, duration: Double?) {
        if let resolved = try? await YouTubeResolver().resolve(videoID: videoID) {
            var playURL = resolved.url
            if resolved.isMasterPlaylist {
                playURL = await prepareQualities(masterURL: resolved.url)
            } else {
                let height = resolved.fallbackHeight.map { "\($0)p" } ?? "a single quality"
                qualityNote = "YouTube only offered \(height) for this video. Retry playback, or update yt-dlp, to get the full quality list."
            }
            guard !Task.isCancelled else { return (.embed(youtubeVideoID: videoID), nil) }
            let player = AVPlayer(url: playURL)
            player.play()
            return (.native(player), resolved.duration)
        }
        return (.embed(youtubeVideoID: videoID), nil)
    }

    // MARK: - Quality

    /// Master playlists list every rendition; parse them so the picker can
    /// constrain AVPlayer to one.
    /// Reads the master playlist and returns the URL to actually play: the
    /// chosen rendition's own playlist (so quality is pinned, not merely
    /// capped), or the master itself under `.auto`. Called before the player
    /// is created so nothing has to be swapped mid-playback.
    private func prepareQualities(masterURL: URL) async -> URL {
        let variants = await HLSPlaylist.fetchVariants(from: masterURL)
        self.masterURL = masterURL
        qualities = variants
        let variant = matchPreferred(in: variants)
        selectedQuality = variant
        return variant?.url ?? masterURL
    }

    /// The user picked a quality — remember it and switch immediately.
    func selectQuality(_ preference: QualityPreference) {
        self.preference = preference
        let variant = matchPreferred(in: qualities)
        guard variant != selectedQuality || preference == .auto else { return }
        selectedQuality = variant
        swapPlayback(to: variant?.url ?? masterURL)
    }

    /// Points the running player at a different rendition, keeping the
    /// position (VODs) and play state.
    private func swapPlayback(to url: URL?) {
        guard let url, let player = currentPlayer else { return }
        if let current = (player.currentItem?.asset as? AVURLAsset)?.url, current == url { return }

        let position = player.currentTime()
        let wasPlaying = player.rate > 0
        let isVOD: Bool
        if case .vod = playback { isVOD = true } else { isVOD = false }

        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if isVOD, position.isValid, position.seconds > 0 {
            player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if wasPlaying {
            player.play()
        }
    }

    /// The rendition matching the current preference: the tallest for
    /// `.best`, nil for `.auto` (meaning play the adaptive master), and for
    /// an explicit height the exact match, else the next one down, else the
    /// lowest on offer.
    private func matchPreferred(in variants: [HLSVariant]) -> HLSVariant? {
        guard !variants.isEmpty else { return nil }
        switch preference {
        case .auto:
            return nil
        case .best:
            // `variants` is sorted tallest first.
            return variants.first
        case .height(let preferredHeight):
            if let exact = variants.first(where: { $0.height == preferredHeight }) {
                return exact
            }
            return variants.first { $0.height <= preferredHeight } ?? variants.last
        }
    }

    private var currentPlayer: AVPlayer? {
        switch playback {
        case .live(.native(let player), _), .vod(.native(let player), _): return player
        default: return nil
        }
    }

    /// Resume partially watched VODs a few seconds before where they left
    /// off; finished or barely-started ones restart. Returns the position
    /// playback will actually start from.
    private func resumeIfNeeded(_ player: AVPlayer, vodID: String) async -> Double {
        guard let saved = watchHistory.progress(for: vodID),
              !saved.finished,
              saved.position > 15,
              saved.position < saved.duration - 30
        else { return 0 }
        let target = saved.position - 5
        _ = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        return target
    }

    private func trackProgress(of player: AVPlayer, vodID: String, duration: Double) {
        guard duration > 0 else { return }
        observedPlayer = player
        progressContext = (vodID, duration)
        progressObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.watchHistory.update(vodID: vodID, position: time.seconds, duration: duration)
            }
        }
    }

    private func attachChatSync(to player: AVPlayer) {
        observedPlayer = player
        chatSyncObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.chatReplay.sync(to: time.seconds)
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
        chatReplay.stop()
        if let observedPlayer {
            if let progressObserver {
                observedPlayer.removeTimeObserver(progressObserver)
                if let context = progressContext {
                    watchHistory.update(
                        vodID: context.vodID,
                        position: observedPlayer.currentTime().seconds,
                        duration: context.duration
                    )
                }
            }
            if let chatSyncObserver {
                observedPlayer.removeTimeObserver(chatSyncObserver)
            }
        }
        progressObserver = nil
        chatSyncObserver = nil
        observedPlayer = nil
        progressContext = nil
        qualities = []
        selectedQuality = nil
        qualityNote = nil
        masterURL = nil
        switch playback {
        case .live(.native(let player), _), .vod(.native(let player), _):
            player.pause()
        default:
            // Embed web views stop when removed from the view hierarchy.
            break
        }
        playback = .none
    }
}
