import Foundation

/// Loads the list of channels the user cares about from channels.json.
///
/// Search order:
/// 1. `channels.json` in the current working directory (handy during `swift run`)
/// 2. `~/Library/Application Support/Twitcher/channels.json`
///
/// If neither exists, a default file is written to Application Support so
/// there's always a file the user can edit.
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
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("channels.json"),
            applicationSupportURL,
        ]

        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let config = try? JSONDecoder().decode(ConfigFile.self, from: data) {
                return (entries(from: config), url)
            }
        }

        // First launch: create a default config the user can edit.
        let url = applicationSupportURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let defaults = ConfigFile(channels: defaultTwitch, youtube: defaultYouTube)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(defaults) {
            try? data.write(to: url)
        }
        return (entries(from: defaults), url)
    }

    /// Appends a YouTube channel to the config file at `url`, keeping the
    /// rest of the file's contents.
    static func addYouTube(_ name: String, to url: URL) throws {
        var config = try JSONDecoder().decode(ConfigFile.self, from: Data(contentsOf: url))
        config.youtube = (config.youtube ?? []) + [name]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    private static func entries(from config: ConfigFile) -> [(platform: Platform, name: String)] {
        let twitch = (config.channels ?? [])
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { (Platform.twitch, $0) }
        let youtube = (config.youtube ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
            .map { (Platform.youtube, $0) }
        return twitch + youtube
    }
}
