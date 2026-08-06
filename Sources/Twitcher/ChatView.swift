import SwiftUI

struct ChatPane: View {
    @ObservedObject var chat: ChatClient
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.secondary)
                Text(chat.channel.map { "#\($0)" } ?? "Chat")
                    .font(.system(size: 13 * zoom, weight: .semibold))
                Spacer()
            }
            .padding(10)
            Divider()

            if chat.channel == nil {
                Text("Chat is available while watching a live stream.")
                    .font(.system(size: 13 * zoom))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                messageList
            }
        }
        .background(.background)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(chat.messages) { message in
                        MessageRow(message: message)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(8)
            }
            .onChange(of: chat.messages.last?.id) {
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
