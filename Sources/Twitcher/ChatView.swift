import SwiftUI

/// Shows live IRC chat while a Twitch stream plays, chat replay while a
/// Twitch VOD plays, and a placeholder otherwise.
struct ChatPane: View {
    @ObservedObject var chat: ChatClient
    @ObservedObject var replay: ChatReplayClient
    @Environment(\.uiZoom) private var zoom

    private var mode: (title: String, messages: [ChatMessage])? {
        if let channel = chat.channel {
            return ("#\(channel)", chat.messages)
        }
        if replay.active {
            return ("Chat replay", replay.messages)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.secondary)
                Text(mode?.title ?? "Chat")
                    .font(.system(size: 13 * zoom, weight: .semibold))
                Spacer()
            }
            .padding(10)
            Divider()

            if let mode {
                messageList(mode.messages)
            } else {
                Text("Chat is available while watching a live Twitch stream or VOD.")
                    .font(.system(size: 13 * zoom))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }

    private func messageList(_ messages: [ChatMessage]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(messages) { message in
                        MessageRow(message: message)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(8)
            }
            .onChange(of: messages.last?.id) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        if message.isSystem {
            Text(message.text)
                .font(.system(size: 10 * zoom))
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            (Text(message.sender).bold().foregroundStyle(message.color ?? .secondary)
                + Text(": ").foregroundStyle(.secondary)
                + Text(message.text))
                .font(.system(size: 12 * zoom))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
