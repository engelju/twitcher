import Foundation

struct WatchProgress: Codable {
    var position: Double
    var duration: Double
    /// Latches true once ~95% has been watched, and stays true even if the
    /// VOD is later reopened from the beginning.
    var finished: Bool
    var updatedAt: Date

    var fraction: Double {
        duration > 0 ? min(max(position / duration, 0), 1) : 0
    }
}

/// Persists per-VOD playback position to
/// `~/Library/Application Support/Twitcher/watch-progress.json`, so
/// partially watched VODs resume where you left off and finished ones can
/// be marked in the broadcast grid.
@MainActor
final class WatchProgressStore: ObservableObject {
    @Published private(set) var entries: [String: WatchProgress] = [:]

    private static let finishedThreshold = 0.95
    private static let maxEntries = 500

    private let fileURL: URL

    init() {
        fileURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Twitcher/watch-progress.json")
        load()
    }

    func progress(for vodID: String) -> WatchProgress? {
        entries[vodID]
    }

    func update(vodID: String, position: Double, duration: Double) {
        guard duration > 0, position.isFinite, position > 0 else { return }
        let clamped = min(position, duration)
        let wasFinished = entries[vodID]?.finished ?? false
        entries[vodID] = WatchProgress(
            position: clamped,
            duration: duration,
            finished: wasFinished || clamped / duration >= Self.finishedThreshold,
            updatedAt: Date()
        )
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([String: WatchProgress].self, from: data)) ?? [:]
    }

    private func save() {
        // Keep the file bounded: drop the oldest entries past the cap.
        if entries.count > Self.maxEntries {
            let newest = entries.sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: Array(newest))
        }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
