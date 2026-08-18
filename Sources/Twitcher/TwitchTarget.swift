import Foundation

/// What to resolve on Twitch: a live channel or a VOD.
enum TwitchTarget: Equatable {
    case live(channel: String)
    case vod(id: String)
}
