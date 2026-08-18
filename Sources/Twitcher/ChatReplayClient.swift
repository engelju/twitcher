import Foundation
import SwiftUI

/// Replays a Twitch VOD's chat in sync with playback, using the GQL video
/// comments API. Comments are fetched by content offset (cursor pagination
/// trips Twitch's integrity check, offset-based paging doesn't), buffered
/// ahead of the playhead, and released as playback passes their timestamps.
@MainActor
final class ChatReplayClient: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var active = false

    private static let maxMessages = 300
    /// Keep this many seconds of chat buffered ahead of the playhead.
    private static let bufferAhead: Double = 30

    private var videoID: String?
    private var buffer: [(offset: Double, message: ChatMessage)] = []
    private var seenIDs: Set<String> = []
    private var hasMore = true
    private var lastFetchedOffset: Double = 0
    private var lastSyncOffset: Double = 0
    private var isFetching = false
    private var fetchTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    func start(videoID: String, at offset: Double) {
        stop()
        self.videoID = videoID
        active = true
        lastSyncOffset = offset
        resetBuffer(around: offset)
        sync(to: offset)
    }

    func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        videoID = nil
        active = false
        buffer = []
        seenIDs = []
        hasMore = true
        isFetching = false
        consecutiveFailures = 0
        messages = []
    }

    /// Called every second with the current playback position.
    func sync(to offset: Double) {
        guard active else { return }
        // A jump backward, or forward past the buffered window, is a seek.
        if offset < lastSyncOffset - 3 || offset > lastSyncOffset + 15 {
            resetBuffer(around: offset)
        }
        lastSyncOffset = offset

        release(upTo: offset)

        let bufferedAhead = buffer.last.map { $0.offset - offset } ?? 0
        if hasMore, !isFetching, bufferedAhead < Self.bufferAhead {
            fetchNext()
        }
    }

    private func resetBuffer(around offset: Double) {
        fetchTask?.cancel()
        buffer = []
        seenIDs = []
        hasMore = true
        consecutiveFailures = 0
        // Start slightly earlier so a few pre-seek messages give context.
        lastFetchedOffset = max(0, offset - Self.bufferAhead)
        messages = [.system("Loading chat replay…")]
    }

    private func release(upTo offset: Double) {
        var appended = false
        while let first = buffer.first, first.offset <= offset {
            buffer.removeFirst()
            if !appended, messages.count == 1, messages[0].isSystem {
                messages = []
            }
            appended = true
            messages.append(first.message)
        }
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }

    private func fetchNext() {
        guard let videoID, !isFetching else { return }
        isFetching = true
        let requestOffset = max(0, Int(lastFetchedOffset))
        fetchTask = Task {
            defer { isFetching = false }
            guard let result = try? await Self.fetchComments(videoID: videoID, offsetSeconds: requestOffset) else {
                guard !Task.isCancelled else { return }
                consecutiveFailures += 1
                if consecutiveFailures >= 3 {
                    hasMore = false
                    messages.append(.system("Chat replay unavailable."))
                }
                return
            }
            guard !Task.isCancelled else { return }
            consecutiveFailures = 0

            var added = 0
            for comment in result.comments where seenIDs.insert(comment.id).inserted {
                buffer.append((comment.offset, comment.message))
                added += 1
            }
            buffer.sort { $0.offset < $1.offset }

            if let maxOffset = result.comments.map(\.offset).max() {
                lastFetchedOffset = max(lastFetchedOffset, maxOffset)
            }
            if added == 0 {
                // Quiet stretch or a chunk we already had — skip ahead so
                // repeated fetches make progress.
                lastFetchedOffset += Self.bufferAhead
            }
            hasMore = result.hasNextPage
        }
    }

    // MARK: - GQL

    private struct FetchResult {
        let comments: [(id: String, offset: Double, message: ChatMessage)]
        let hasNextPage: Bool
    }

    private struct Response: Decodable {
        let data: DataField?
        struct DataField: Decodable { let video: Video? }
        struct Video: Decodable { let comments: Comments? }
        struct Comments: Decodable {
            let edges: [Edge]
            let pageInfo: PageInfo?
        }
        struct PageInfo: Decodable { let hasNextPage: Bool? }
        struct Edge: Decodable { let node: Node }
        struct Node: Decodable {
            let id: String
            let contentOffsetSeconds: Double?
            let commenter: Commenter?
            let message: Message?
        }
        struct Commenter: Decodable { let displayName: String? }
        struct Message: Decodable {
            let userColor: String?
            let fragments: [Fragment]?
        }
        struct Fragment: Decodable { let text: String? }
    }

    private static func fetchComments(videoID: String, offsetSeconds: Int) async throws -> FetchResult {
        let query = """
        query VodComments($videoID: ID!, $offset: Int!) {
          video(id: $videoID) {
            comments(contentOffsetSeconds: $offset, first: 100) {
              edges {
                node {
                  id
                  contentOffsetSeconds
                  commenter { displayName }
                  message {
                    userColor
                    fragments { text }
                  }
                }
              }
              pageInfo { hasNextPage }
            }
          }
        }
        """
        let data = try await GQLClient().post(
            operationName: "VodComments",
            query: query,
            variables: ["videoID": videoID, "offset": offsetSeconds]
        )
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let comments = decoded.data?.video?.comments else {
            throw URLError(.badServerResponse)
        }

        let items = comments.edges.compactMap { edge -> (String, Double, ChatMessage)? in
            let node = edge.node
            guard let offset = node.contentOffsetSeconds else { return nil }
            let text = (node.message?.fragments ?? []).compactMap(\.text).joined()
            guard !text.isEmpty else { return nil }
            let message = ChatMessage(
                sender: node.commenter?.displayName ?? "anonymous",
                color: node.message?.userColor.flatMap(Color.init(twitchHex:)),
                text: text,
                isSystem: false
            )
            return (node.id, offset, message)
        }
        return FetchResult(
            comments: items.map { (id: $0.0, offset: $0.1, message: $0.2) },
            hasNextPage: comments.pageInfo?.hasNextPage ?? false
        )
    }
}
