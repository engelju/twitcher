import Foundation

/// What the user asked to watch: a live channel or a VOD.
enum TwitchTarget: Equatable {
    case live(channel: String)
    case vod(id: String)

    /// Accepts a bare channel name ("xqc"), a channel URL
    /// ("https://twitch.tv/xqc"), or a VOD URL ("twitch.tv/videos/123456").
    static func parse(_ input: String) -> TwitchTarget? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let range = trimmed.range(of: "/videos/") {
            let id = trimmed[range.upperBound...].prefix { $0.isNumber }
            return id.isEmpty ? nil : .vod(id: String(id))
        }

        // Strip scheme/host if a URL was pasted; the last path component is the login.
        var candidate = trimmed
        if candidate.contains("/") {
            guard let last = candidate.split(separator: "/").last else { return nil }
            candidate = String(last)
        }
        candidate = candidate.lowercased()

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return .live(channel: candidate)
    }
}
