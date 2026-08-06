import Foundation

/// Resolves a Twitch channel or VOD into a playable HLS master-playlist URL.
///
/// This uses the same flow as the Twitch web player (and streamlink/yt-dlp):
/// 1. Ask Twitch's GraphQL endpoint for a playback access token.
/// 2. Build a usher.ttvnw.net playlist URL carrying that token.
///
/// Note this endpoint is unofficial — if Twitch changes it, this file is the
/// one that will need updating.
struct StreamResolver {
    /// Public client ID used by the Twitch web player.
    private static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    private static let gqlURL = URL(string: "https://gql.twitch.tv/gql")!

    enum ResolverError: LocalizedError {
        case notFound(TwitchTarget)
        case offline(channel: String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notFound(.live(let channel)):
                return "Channel “\(channel)” doesn’t exist."
            case .notFound(.vod(let id)):
                return "VOD \(id) doesn’t exist (it may have been deleted)."
            case .offline(let channel):
                return "“\(channel)” is offline."
            case .badResponse(let detail):
                return "Twitch returned an unexpected response: \(detail)"
            }
        }
    }

    func resolve(_ target: TwitchTarget) async throws -> URL {
        let token = try await fetchAccessToken(for: target)
        let playlistURL = usherURL(for: target, token: token)
        try await verifyPlayable(playlistURL, target: target)
        return playlistURL
    }

    // MARK: - Access token (GraphQL)

    private struct AccessToken: Decodable {
        let value: String
        let signature: String
    }

    private struct GQLResponse: Decodable {
        struct DataField: Decodable {
            let streamPlaybackAccessToken: AccessToken?
            let videoPlaybackAccessToken: AccessToken?
        }
        let data: DataField?
    }

    private func fetchAccessToken(for target: TwitchTarget) async throws -> AccessToken {
        // Full query text rather than a persisted-query hash: hashes go stale
        // when Twitch redeploys, the query text keeps working.
        let query = """
        query PlaybackAccessToken_Template($login: String!, $isLive: Boolean!, $vodID: ID!, $isVod: Boolean!, $playerType: String!) {
          streamPlaybackAccessToken(channelName: $login, params: {platform: "web", playerBackend: "mediaplayer", playerType: $playerType}) @include(if: $isLive) {
            value
            signature
          }
          videoPlaybackAccessToken(id: $vodID, params: {platform: "web", playerBackend: "mediaplayer", playerType: $playerType}) @include(if: $isVod) {
            value
            signature
          }
        }
        """

        var variables: [String: Any] = ["playerType": "site"]
        switch target {
        case .live(let channel):
            variables["isLive"] = true
            variables["login"] = channel
            variables["isVod"] = false
            variables["vodID"] = ""
        case .vod(let id):
            variables["isLive"] = false
            variables["login"] = ""
            variables["isVod"] = true
            variables["vodID"] = id
        }

        var request = URLRequest(url: Self.gqlURL)
        request.httpMethod = "POST"
        request.setValue(Self.clientID, forHTTPHeaderField: "Client-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "operationName": "PlaybackAccessToken_Template",
            "query": query,
            "variables": variables,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ResolverError.badResponse("GQL HTTP \(code)")
        }

        let decoded = try JSONDecoder().decode(GQLResponse.self, from: data)
        let token: AccessToken?
        switch target {
        case .live: token = decoded.data?.streamPlaybackAccessToken
        case .vod: token = decoded.data?.videoPlaybackAccessToken
        }
        guard let token else { throw ResolverError.notFound(target) }
        return token
    }

    // MARK: - Playlist URL (usher)

    private func usherURL(for target: TwitchTarget, token: AccessToken) -> URL {
        var components: URLComponents
        switch target {
        case .live(let channel):
            components = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(channel).m3u8")!
        case .vod(let id):
            components = URLComponents(string: "https://usher.ttvnw.net/vod/\(id).m3u8")!
        }

        var items = [
            URLQueryItem(name: "token", value: token.value),
            URLQueryItem(name: "sig", value: token.signature),
            URLQueryItem(name: "allow_source", value: "true"),
            URLQueryItem(name: "allow_audio_only", value: "true"),
            URLQueryItem(name: "player_backend", value: "mediaplayer"),
            URLQueryItem(name: "playlist_include_framerate", value: "true"),
            URLQueryItem(name: "p", value: String(Int.random(in: 1_000_000...9_999_999))),
        ]
        if case .live = target {
            // Opt in to low-latency HLS segments.
            items.append(URLQueryItem(name: "fast_bread", value: "true"))
        }
        components.queryItems = items
        return components.url!
    }

    /// Fetch the master playlist once so we can surface a clean error
    /// (offline, deleted VOD) instead of AVPlayer's generic failure.
    private func verifyPlayable(_ url: URL, target: TwitchTarget) async throws {
        let (_, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ResolverError.badResponse("usher: no HTTP response")
        }
        switch http.statusCode {
        case 200:
            return
        case 404:
            if case .live(let channel) = target {
                throw ResolverError.offline(channel: channel)
            }
            throw ResolverError.notFound(target)
        default:
            throw ResolverError.badResponse("usher HTTP \(http.statusCode)")
        }
    }
}
