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
        var channels: [String]
    }

    static let defaultChannels = ["twitch", "twitchdev"]

    static var applicationSupportURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Twitcher/channels.json")
    }

    static func load() -> (channels: [String], path: URL) {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("channels.json"),
            applicationSupportURL,
        ]

        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let config = try? JSONDecoder().decode(ConfigFile.self, from: data) {
                let logins = config.channels
                    .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return (logins, url)
            }
        }

        // First launch: create a default config the user can edit.
        let url = applicationSupportURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(ConfigFile(channels: defaultChannels)) {
            try? data.write(to: url)
        }
        return (defaultChannels, url)
    }
}
