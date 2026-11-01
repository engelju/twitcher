import Foundation

/// Loads the list of channels the user cares about from
/// `~/Library/Application Support/Twitcher/channels.json`.
///
/// If it doesn't exist, a default file is written so there's always one the
/// user can edit.
enum ChannelStore {
    struct ConfigFile: Codable {
        /// Twitch logins.
        var channels: [String]?
        /// YouTube handles (with or without the leading @).
        var youtube: [String]?
    }

    static let defaultTwitch = ["twitch", "twitchdev"]
    static let defaultYouTube = [
        "YouTube", "GoogleDevelopers",
    ]

    static var applicationSupportURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Twitcher/channels.json")
    }

    static func load() -> (entries: [(platform: Platform, name: String)], path: URL) {
        let url = applicationSupportURL
        let defaults = ConfigFile(channels: defaultTwitch, youtube: defaultYouTube)

        if FileManager.default.fileExists(atPath: url.path) {
            // An unreadable file (e.g. a typo while hand-editing) falls back
            // to the defaults for this session but is never overwritten.
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(ConfigFile.self, from: data)
            else { return (entries(from: defaults), url) }
            return (entries(from: config), url)
        }

        // First launch: create a default config the user can edit.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(defaults) {
            try? data.write(to: url)
        }
        return (entries(from: defaults), url)
    }

    /// Appends a YouTube channel to the config file at `url`.
    static func addYouTube(_ name: String, to url: URL) throws {
        try update(url) { config in
            config.youtube = (config.youtube ?? []) + [name]
        }
    }

    /// Removes every entry for a channel from the config file at `url`,
    /// however it was written (case, leading @, whitespace).
    static func remove(_ platform: Platform, _ name: String, from url: URL) throws {
        try update(url) { config in
            switch platform {
            case .twitch:
                config.channels = config.channels?.filter { normalizedTwitch($0) != name }
            case .youtube:
                config.youtube = config.youtube?.filter {
                    normalizedYouTube($0).lowercased() != name.lowercased()
                }
            }
        }
    }

    /// Sorts a platform's entries to match `names` (normalized, as loaded),
    /// keeping each entry as written. Unmatched entries go last.
    static func reorder(_ platform: Platform, _ names: [String], in url: URL) throws {
        try update(url) { config in
            switch platform {
            case .twitch:
                config.channels = config.channels.map { sorted($0, by: names, key: normalizedTwitch) }
            case .youtube:
                config.youtube = config.youtube.map {
                    sorted($0, by: names.map { $0.lowercased() }) { normalizedYouTube($0).lowercased() }
                }
            }
        }
    }

    private static func sorted(_ entries: [String], by names: [String], key: (String) -> String) -> [String] {
        let rank = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.enumerated()
            .sorted { a, b in
                (rank[key(a.element)] ?? Int.max, a.offset) < (rank[key(b.element)] ?? Int.max, b.offset)
            }
            .map(\.element)
    }

    private static func update(_ url: URL, _ change: (inout ConfigFile) -> Void) throws {
        var config = try JSONDecoder().decode(ConfigFile.self, from: Data(contentsOf: url))
        change(&config)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    private static func entries(from config: ConfigFile) -> [(platform: Platform, name: String)] {
        let twitch = (config.channels ?? [])
            .map(normalizedTwitch)
            .filter { !$0.isEmpty }
            .map { (Platform.twitch, $0) }
        let youtube = (config.youtube ?? [])
            .map(normalizedYouTube)
            .filter { !$0.isEmpty }
            .map { (Platform.youtube, $0) }
        return twitch + youtube
    }

    private static func normalizedTwitch(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private static func normalizedYouTube(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }
}
