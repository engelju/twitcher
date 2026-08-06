import Foundation

/// Fetches channel metadata (live status, profile, recent VODs) via GQL.
struct TwitchAPI {
    private static let channelQuery = """
    query ChannelOverview($login: String!) {
      user(login: $login) {
        displayName
        profileImageURL(width: 70)
        stream {
          title
          viewersCount
          game { displayName }
        }
        videos(first: 20, type: ARCHIVE, sort: TIME) {
          edges {
            node {
              id
              title
              publishedAt
              lengthSeconds
              previewThumbnailURL(width: 320, height: 180)
              game { displayName }
            }
          }
        }
      }
    }
    """

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
        struct Videos: Decodable { let edges: [Edge] }
        struct Edge: Decodable { let node: Video }
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
    func fetchChannel(login: String) async -> ChannelInfo? {
        guard let data = try? await GQLClient().post(
            operationName: "ChannelOverview",
            query: Self.channelQuery,
            variables: ["login": login]
        ) else { return nil }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let user = decoded.data?.user else { return nil }

        let dateParser = ISO8601DateFormatter()
        let vods: [VodInfo] = (user.videos?.edges ?? []).map { edge in
            let node = edge.node
            let published: Date? = node.publishedAt.flatMap { dateParser.date(from: $0) }
            let thumbnail: URL? = node.previewThumbnailURL.flatMap { URL(string: $0) }
            return VodInfo(
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
            login: login,
            displayName: user.displayName ?? login,
            avatarURL: user.profileImageURL.flatMap { URL(string: $0) },
            live: live,
            vods: vods,
            isPlaceholder: false
        )
    }
}
