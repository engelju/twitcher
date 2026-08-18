import Foundation

/// One selectable rendition from an HLS master playlist.
struct HLSVariant: Identifiable, Equatable {
    var id: String { "\(width)x\(height)@\(bandwidth)" }
    let width: Int
    let height: Int
    let bandwidth: Int
    let frameRate: Double?
    /// The rendition's own media playlist. Playing this directly pins
    /// quality, since there are no other renditions to switch between.
    let url: URL

    /// "1080p60", "720p", … — derived from resolution rather than the
    /// playlist's own NAME/VIDEO attribute, which differs per platform
    /// (Twitch calls its source rendition "chunked").
    var label: String {
        let base = "\(height)p"
        if let frameRate, frameRate >= 50 {
            return base + String(Int(frameRate.rounded()))
        }
        return base
    }
}

enum HLSPlaylist {
    /// Parses the `#EXT-X-STREAM-INF` entries of a master playlist, pairing
    /// each with the URI on the following line (resolved against `baseURL`).
    /// Audio-only renditions (no RESOLUTION) are skipped, and when several
    /// variants share a label the highest-bandwidth one wins.
    static func parseVariants(_ text: String, baseURL: URL? = nil) -> [HLSVariant] {
        var variants: [HLSVariant] = []
        var pending: (width: Int, height: Int, bandwidth: Int, frameRate: Double?)?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = nil
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                guard let resolution = attributes["RESOLUTION"] else { continue }
                let dimensions = resolution.split(separator: "x")
                guard dimensions.count == 2,
                      let width = Int(dimensions[0]),
                      let height = Int(dimensions[1])
                else { continue }
                pending = (
                    width, height,
                    attributes["BANDWIDTH"].flatMap { Int($0) } ?? 0,
                    attributes["FRAME-RATE"].flatMap { Double($0) }
                )
            } else if line.hasPrefix("#") {
                continue
            } else if let info = pending {
                pending = nil
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
                variants.append(HLSVariant(
                    width: info.width,
                    height: info.height,
                    bandwidth: info.bandwidth,
                    frameRate: info.frameRate,
                    url: url
                ))
            }
        }

        var best: [String: HLSVariant] = [:]
        for variant in variants {
            if let existing = best[variant.label], existing.bandwidth >= variant.bandwidth { continue }
            best[variant.label] = variant
        }
        return best.values.sorted {
            $0.height != $1.height ? $0.height > $1.height : $0.bandwidth > $1.bandwidth
        }
    }

    /// Splits `KEY=VALUE,KEY="quoted,value"` lists, honoring quotes.
    private static func parseAttributes(_ text: String) -> [String: String] {
        var attributes: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var inQuotes = false

        func commit() {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            if !trimmedKey.isEmpty {
                attributes[trimmedKey] = value.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            }
            key = ""
            value = ""
            readingKey = true
        }

        for character in text {
            switch character {
            case "\"":
                inQuotes.toggle()
                value.append(character)
            case "=" where readingKey && !inQuotes:
                readingKey = false
            case "," where !inQuotes:
                commit()
            default:
                if readingKey { key.append(character) } else { value.append(character) }
            }
        }
        commit()
        return attributes
    }

    /// Fetches and parses a master playlist; returns [] on any failure so
    /// callers can simply fall back to automatic quality selection.
    static func fetchVariants(from url: URL) async -> [HLSVariant] {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return parseVariants(text, baseURL: url)
    }
}
