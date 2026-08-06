import Foundation

struct ChannelInfo: Identifiable, Equatable {
    var id: String { login }
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
}

struct VodInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let publishedAt: Date?
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
