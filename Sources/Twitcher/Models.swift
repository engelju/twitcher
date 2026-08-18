import Foundation

enum Platform: String {
    case twitch
    case youtube
}

struct ChannelInfo: Identifiable, Equatable {
    /// Platform-qualified so a Twitch channel and YouTube handle with the
    /// same name can coexist.
    var id: String { "\(platform.rawValue):\(login)" }
    let platform: Platform
    /// Twitch login or YouTube handle (without the leading @).
    let login: String
    var displayName: String
    var avatarURL: URL?
    var live: LiveInfo?
    var vods: [VodInfo]
    /// Still waiting for the first successful info fetch.
    var isPlaceholder = true
}

struct LiveInfo: Equatable {
    var title: String
    var game: String?
    var viewers: Int
    /// YouTube only: the video ID of the current live stream.
    var videoID: String?
}

struct VodInfo: Identifiable, Equatable {
    let platform: Platform
    let id: String
    let title: String
    let publishedAt: Date?
    /// 0 when unknown (YouTube's feed doesn't include durations).
    let lengthSeconds: Int
    let thumbnailURL: URL?
    let game: String?

    var formattedLength: String {
        let h = lengthSeconds / 3600
        let m = (lengthSeconds % 3600) / 60
        let s = lengthSeconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    var formattedAge: String {
        guard let publishedAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: publishedAt, relativeTo: Date())
    }
}
