import Foundation
import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let sender: String
    let color: Color?
    let text: String
    let isSystem: Bool

    static func system(_ text: String) -> ChatMessage {
        ChatMessage(sender: "", color: nil, text: text, isSystem: true)
    }
}

/// Read-only Twitch chat over the IRC WebSocket gateway.
///
/// Uses the anonymous `justinfan` login, which Twitch allows for reading —
/// no account or OAuth needed (and no way to send messages).
@MainActor
final class ChatClient: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var channel: String?

    private static let gateway = URL(string: "wss://irc-ws.chat.twitch.tv:443")!
    private static let maxMessages = 300

    private var socket: URLSessionWebSocketTask?
    private var listenTask: Task<Void, Never>?

    func connect(to channel: String) {
        disconnect()
        self.channel = channel
        messages = [.system("Joining #\(channel)…")]

        let socket = URLSession.shared.webSocketTask(with: Self.gateway)
        self.socket = socket
        socket.resume()

        send("CAP REQ :twitch.tv/tags twitch.tv/commands")
        send("NICK justinfan\(Int.random(in: 10_000...99_999))")
        send("JOIN #\(channel)")

        listen(on: socket)
    }

    func disconnect() {
        listenTask?.cancel()
        listenTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        channel = nil
        messages = []
    }

    private func send(_ line: String) {
        socket?.send(.string(line + "\r\n")) { _ in }
    }

    private func listen(on socket: URLSessionWebSocketTask) {
        listenTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await socket.receive()
                    guard let self, self.socket === socket else { return }
                    if case .string(let raw) = frame {
                        self.handle(raw: raw)
                    }
                } catch {
                    guard let self, self.socket === socket, !Task.isCancelled else { return }
                    self.append(.system("Chat disconnected."))
                    return
                }
            }
        }
    }

    private func handle(raw: String) {
        for line in raw.split(separator: "\r\n") {
            if line.hasPrefix("PING") {
                send("PONG :tmi.twitch.tv")
            } else if let message = Self.parsePrivmsg(String(line)) {
                append(message)
            }
        }
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }

    // MARK: - IRC parsing

    /// Parses a tagged PRIVMSG line, e.g.
    /// `@color=#FF0000;display-name=Foo :foo!foo@foo.tmi.twitch.tv PRIVMSG #chan :hello`
    static func parsePrivmsg(_ line: String) -> ChatMessage? {
        var rest = Substring(line)

        var tags: [String: String] = [:]
        if rest.hasPrefix("@") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            for pair in rest[rest.index(after: rest.startIndex)..<space].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2 {
                    tags[String(kv[0])] = String(kv[1])
                }
            }
            rest = rest[rest.index(after: space)...]
        }

        var nick = ""
        if rest.hasPrefix(":") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            nick = String(rest.dropFirst().prefix(while: { $0 != "!" && $0 != " " }))
            rest = rest[rest.index(after: space)...]
        }

        guard rest.hasPrefix("PRIVMSG ") else { return nil }
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let text = String(rest[rest.index(after: colon)...])

        let displayName = tags["display-name"]
            .map { $0.replacingOccurrences(of: "\\s", with: " ") }
            .flatMap { $0.isEmpty ? nil : $0 }

        return ChatMessage(
            sender: displayName ?? nick,
            color: tags["color"].flatMap(Color.init(twitchHex:)),
            text: text,
            isSystem: false
        )
    }
}

extension Color {
    /// Parses Twitch's "#RRGGBB" chat colors; returns nil for empty/invalid.
    init?(twitchHex hex: String) {
        guard hex.hasPrefix("#"), hex.count == 7,
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
