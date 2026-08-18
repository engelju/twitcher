import Foundation

/// Resolves a YouTube video ID to an AVPlayer-playable URL by shelling out
/// to yt-dlp. YouTube's own endpoints require proof-of-origin tokens these
/// days, which only actively maintained extractors like yt-dlp keep up with.
/// When yt-dlp is unavailable or fails, callers fall back to the official
/// embed player in a web view.
struct YouTubeResolver {
    struct Resolved {
        let url: URL
        /// Seconds; nil for live streams or when unknown.
        let duration: Double?
        /// True when `url` is an HLS master playlist, meaning every quality
        /// is available and the quality picker has something to offer.
        let isMasterPlaylist: Bool
        /// Height of the single available rendition when not a master.
        let fallbackHeight: Int?
    }

    enum ResolverError: LocalizedError {
        case ytDLPNotFound
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .ytDLPNotFound:
                return "yt-dlp is not installed."
            case .extractionFailed(let detail):
                return "yt-dlp failed: \(detail)"
            }
        }
    }

    /// YouTube only hands out an HLS manifest to some of the player clients
    /// yt-dlp rotates through, and the non-HLS path tops out at 360p. Retry
    /// a few times to land on a client that offers the full-quality master.
    private static let hlsAttempts = 4

    /// GUI apps don't inherit a shell PATH, so check the usual spots.
    static func findYTDLP() -> String? {
        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
            "\(NSHomeDirectory())/.local/bin/yt-dlp",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func resolve(videoID: String) async throws -> Resolved {
        guard let binary = Self.findYTDLP() else {
            throw ResolverError.ytDLPNotFound
        }

        var lastFallback: Resolved?
        var lastError = "no output"

        for _ in 0..<Self.hlsAttempts {
            if Task.isCancelled { break }

            // Prefer HLS: its master manifest carries every quality in one
            // URL that AVPlayer can play and the picker can constrain.
            let result = try await Subprocess.run(binary, arguments: [
                "--no-warnings",
                "--no-playlist",
                "-f", "b[protocol^=m3u8]/b",
                "--print", "%(protocol)s",
                "--print", "%(manifest_url)s",
                "--print", "%(url)s",
                "--print", "%(duration)s",
                "--print", "%(height)s",
                "https://www.youtube.com/watch?v=\(videoID)",
            ])

            guard result.status == 0 else {
                lastError = result.stderr
                    .split(separator: "\n")
                    .first { $0.contains("ERROR") }
                    .map(String.init) ?? "exit \(result.status)"
                continue
            }

            let lines = result.stdout.split(separator: "\n").map(String.init)
            guard lines.count >= 5 else {
                lastError = "unexpected yt-dlp output"
                continue
            }
            let (protocolName, manifest, directURL) = (lines[0], lines[1], lines[2])
            let duration = Double(lines[3])
            let height = Int(lines[4])

            if protocolName.hasPrefix("m3u8"), manifest != "NA", let url = URL(string: manifest) {
                return Resolved(
                    url: url, duration: duration,
                    isMasterPlaylist: true, fallbackHeight: height
                )
            }
            if lastFallback == nil, let url = URL(string: directURL) {
                lastFallback = Resolved(
                    url: url, duration: duration,
                    isMasterPlaylist: false, fallbackHeight: height
                )
            }
        }

        if let lastFallback {
            return lastFallback
        }
        throw ResolverError.extractionFailed(lastError)
    }
}
