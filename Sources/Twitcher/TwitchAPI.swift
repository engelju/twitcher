import Foundation

/// Fetches channel metadata (live status, profile, recent VODs) via GQL.
struct TwitchAPI {
    private static let channelQuery = """
    query ChannelOverview($login: String!, $after: Cursor) {
      user(login: $login) {
        displayName
        profileImageURL(width: 70)
        stream {
          title
          viewersCount
          game { displayName }
        }
        videos(first: 100, after: $after, type: ARCHIVE, sort: TIME) {
          edges {
            cursor
            node {
              id
              title
              publishedAt
              lengthSeconds
              previewThumbnailURL(width: 320, height: 180)
              game { displayName }
            }
          }
          pageInfo { hasNextPage }
        }
      }
    }
    """

    /// Safety cap on pagination — Twitch VODs expire after 7–60 days, so
    /// real archives are far smaller than this.
    private static let maxVods = 500

    private struct Response: Decodable {
        let data: DataField?
        struct DataField: Decodable { let user: User? }
        struct User: Decodable {
            let displayName: String?
            let profileImageURL: String?
            let stream: Stream?
            let videos: Videos?
        }
        struct Stream: Decodable {
            let title: String?
            let viewersCount: Int?
            let game: Game?
        }
        struct Game: Decodable { let displayName: String? }
        struct Videos: Decodable {
            let edges: [Edge]
            let pageInfo: PageInfo?
        }
        struct PageInfo: Decodable { let hasNextPage: Bool? }
        struct Edge: Decodable {
            let cursor: String?
            let node: Video
        }
        struct Video: Decodable {
            let id: String
            let title: String?
            let publishedAt: String?
            let lengthSeconds: Int?
            let previewThumbnailURL: String?
            let game: Game?
        }
    }

    /// Returns nil when the fetch fails or the channel doesn't exist.
    /// Follows the videos cursor to collect the channel's full VOD archive.
    func fetchChannel(login: String) async -> ChannelInfo? {
        var user: Response.User?
        var edges: [Response.Edge] = []
        var after: String?

        while edges.count < Self.maxVods {
            var variables: [String: Any] = ["login": login]
            if let after {
                variables["after"] = after
            }
            guard let data = try? await GQLClient().post(
                operationName: "ChannelOverview",
                query: Self.channelQuery,
                variables: variables
            ), let decoded = try? JSONDecoder().decode(Response.self, from: data),
               let page = decoded.data?.user
            else { break }

            if user == nil {
                user = page
            }
            edges.append(contentsOf: page.videos?.edges ?? [])

            guard page.videos?.pageInfo?.hasNextPage == true,
                  let cursor = page.videos?.edges.last?.cursor, !cursor.isEmpty
            else { break }
            after = cursor
        }

        guard let user else { return nil }

        let dateParser = ISO8601DateFormatter()
        let vods: [VodInfo] = edges.map { edge in
            let node = edge.node
            let published: Date? = node.publishedAt.flatMap { dateParser.date(from: $0) }
            let thumbnail: URL? = node.previewThumbnailURL.flatMap { URL(string: $0) }
            return VodInfo(
                platform: .twitch,
                id: node.id,
                title: node.title ?? "Untitled broadcast",
                publishedAt: published,
                lengthSeconds: node.lengthSeconds ?? 0,
                thumbnailURL: thumbnail,
                game: node.game?.displayName
            )
        }

        let live = user.stream.map { stream in
            LiveInfo(
                title: stream.title ?? "",
                game: stream.game?.displayName,
                viewers: stream.viewersCount ?? 0
            )
        }

        return ChannelInfo(
            platform: .twitch,
            login: login,
            displayName: user.displayName ?? login,
            avatarURL: user.profileImageURL.flatMap { URL(string: $0) },
            live: live,
            vods: vods,
            isPlaceholder: false
        )
    }
}
