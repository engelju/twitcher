import Foundation

/// Fetches YouTube channel metadata without an API key:
/// - the channel's `/live` page (HTML) for channel ID, avatar, and live status
/// - the official RSS feed for the recent-videos list
struct YouTubeAPI {
    /// `handle` may also be a UC… channel ID, for channels without a handle.
    /// Returns nil when the fetch fails or the channel doesn't exist.
    func fetchChannel(handle: String) async -> ChannelInfo? {
        let path = Self.isChannelID(handle)
            ? "channel/\(handle)"
            : "@" + (handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle)
        guard let html = await fetchHTML("https://www.youtube.com/\(path)/live"),
              let channelID = Self.firstMatch(#""externalId":"(UC[0-9A-Za-z_-]{22})""#, in: html)
                ?? Self.firstMatch(#""channelId":"(UC[0-9A-Za-z_-]{22})""#, in: html)
        else { return nil }

        let avatarURL = Self.firstMatch(#"(https://yt3\.googleusercontent\.com/[0-9A-Za-z_\-=/]+)"#, in: html)
            .flatMap { URL(string: $0) }

        // Live when the canonical URL is a watch page AND the player says so
        // (an upcoming stream has a watch canonical but isLive is false).
        var live: LiveInfo?
        if html.contains(#""isLive":true"#),
           let videoID = Self.firstMatch(
               #"<link rel="canonical" href="https://www\.youtube\.com/watch\?v=([0-9A-Za-z_-]{11})""#,
               in: html
           ) {
            let title = Self.firstMatch(#"<meta property="og:title" content="([^"]*)""#, in: html)
                .map(Self.decodeHTMLEntities)
            live = LiveInfo(title: title ?? "Live", game: nil, viewers: 0, videoID: videoID)
        }

        guard let feed = await fetchFeed(channelID: channelID) else { return nil }

        // The RSS feed only carries the latest 15 videos. When yt-dlp is
        // available, list the channel's uploads playlist instead — up to 100
        // videos, durations included (RSS still supplies the publish dates
        // it knows). Without yt-dlp, fall back to the feed's 15.
        let rssDates = Dictionary(
            feed.entries.map { ($0.videoID, $0.published) },
            uniquingKeysWith: { first, _ in first }
        )
        let vods = await fetchAllVideos(
            channelID: channelID,
            rssDates: rssDates,
            excludingLiveID: live?.videoID
        ) ?? feed.entries
            .filter { $0.videoID != live?.videoID }
            .map { entry in
                VodInfo(
                    platform: .youtube,
                    id: entry.videoID,
                    title: entry.title,
                    publishedAt: entry.published,
                    lengthSeconds: 0,
                    thumbnailURL: thumbnailURL(for: entry.videoID),
                    game: nil
                )
            }

        return ChannelInfo(
            platform: .youtube,
            login: handle,
            displayName: feed.channelTitle.isEmpty ? handle : feed.channelTitle,
            avatarURL: avatarURL,
            live: live,
            vods: vods,
            isPlaceholder: false,
            youtubeChannelID: channelID
        )
    }

    static func isChannelID(_ value: String) -> Bool {
        value.count == 24 && value.hasPrefix("UC")
    }

    // MARK: - Full video list via yt-dlp

    /// Lists the channel's uploads playlist (UC… → UU…) with a flat
    /// extraction. Returns nil when yt-dlp is unavailable or fails, so the
    /// caller can fall back to the RSS feed.
    private func fetchAllVideos(
        channelID: String,
        rssDates: [String: Date?],
        excludingLiveID liveID: String?
    ) async -> [VodInfo]? {
        guard let binary = YouTubeResolver.findYTDLP() else { return nil }
        let playlistID = "UU" + channelID.dropFirst(2)
        guard let result = try? await Subprocess.run(binary, arguments: [
            "--no-warnings",
            "--flat-playlist",
            "-J",
            "https://www.youtube.com/playlist?list=\(playlistID)",
        ]), result.status == 0 else { return nil }

        struct FlatPlaylist: Decodable {
            struct Entry: Decodable {
                let id: String
                let title: String?
                let duration: Double?
            }
            let entries: [Entry]?
        }
        guard let flat = try? JSONDecoder().decode(FlatPlaylist.self, from: Data(result.stdout.utf8)),
              let entries = flat.entries, !entries.isEmpty
        else { return nil }

        // Entries without a duration are currently-live or upcoming streams.
        return entries
            .filter { $0.id != liveID && ($0.duration ?? 0) > 0 }
            .map { entry in
                VodInfo(
                    platform: .youtube,
                    id: entry.id,
                    title: entry.title ?? "Untitled",
                    publishedAt: rssDates[entry.id] ?? nil,
                    lengthSeconds: Int(entry.duration ?? 0),
                    thumbnailURL: thumbnailURL(for: entry.id),
                    game: nil
                )
            }
    }

    private func thumbnailURL(for videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")
    }

    // MARK: - HTTP

    private func fetchHTML(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        // Skips the EU consent interstitial that would otherwise replace the page.
        request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func fetchFeed(channelID: String) async -> FeedParser.Result? {
        guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return FeedParser.parse(data)
    }

    /// og:title comes HTML-escaped; cover the entities YouTube actually emits.
    private static func decodeHTMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        let rangeIndex = match.numberOfRanges > 1 ? 1 : 0
        guard let range = Range(match.range(at: rangeIndex), in: text) else { return nil }
        return String(text[range])
    }
}

/// Minimal parser for YouTube's channel Atom feed.
private final class FeedParser: NSObject, XMLParserDelegate {
    struct Entry {
        var videoID = ""
        var title = ""
        var published: Date?
    }

    struct Result {
        var channelTitle: String
        var entries: [Entry]
    }

    static func parse(_ data: Data) -> Result? {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return Result(
            channelTitle: delegate.channelTitle,
            entries: delegate.entries.filter { !$0.videoID.isEmpty }
        )
    }

    private var channelTitle = ""
    private var entries: [Entry] = []
    private var current: Entry?
    private var text = ""
    private let dateParser = ISO8601DateFormatter()

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        if elementName == "entry" {
            current = Entry()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "entry":
            if let entry = current {
                entries.append(entry)
            }
            current = nil
        case "yt:videoId":
            current?.videoID = value
        case "title":
            if current != nil {
                current?.title = value
            } else if channelTitle.isEmpty {
                channelTitle = value
            }
        case "published":
            current?.published = dateParser.date(from: value)
        default:
            break
        }
    }
}
