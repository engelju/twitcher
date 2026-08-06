import AVKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            DetailView(model: model)
        }
        .environment(\.uiZoom, model.zoom)
        .background(
            // The menu's "Zoom In" is ⌘+ (i.e. ⇧⌘=); this invisible button
            // makes plain ⌘= work too, like browsers do.
            Button("") { model.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .task { await model.start() }
        .onChange(of: model.selectedLogin) {
            model.selectionChanged()
        }
        .onChange(of: model.detailTab) {
            model.applyTab()
        }
    }
}

struct DetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.showChat {
                Divider()
                ChatPane(chat: model.chat)
                    .frame(width: 300 * model.zoom)
                    .transition(.move(edge: .trailing))
            }
        }
        .toolbar {
            if model.selectedChannel != nil {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $model.detailTab) {
                        Text("Stream").tag(AppModel.DetailTab.stream)
                        Text("Broadcasts").tag(AppModel.DetailTab.broadcasts)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            ToolbarItem {
                Toggle(isOn: $model.showChat.animation(.easeInOut(duration: 0.15))) {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .help(model.showChat ? "Hide chat" : "Show chat")
            }
        }
        .navigationTitle(model.selectedChannel?.displayName ?? "Twitcher")
    }

    @ViewBuilder
    private var mainContent: some View {
        if let channel = model.selectedChannel {
            switch model.detailTab {
            case .stream: streamContent(channel)
            case .broadcasts: broadcastsContent(channel)
            }
        } else {
            placeholder(icon: "play.tv", text: "Select a channel from the sidebar.")
        }
    }

    // MARK: - Stream tab

    @ViewBuilder
    private func streamContent(_ channel: ChannelInfo) -> some View {
        if channel.live == nil {
            placeholder(
                icon: "moon.zzz",
                text: channel.isPlaceholder
                    ? "Loading…"
                    : "\(channel.displayName) is offline. Check Broadcasts for recent VODs."
            )
        } else {
            switch model.playback {
            case .loading(_, let message):
                loadingView(message)
            case .live(let player, _):
                PlayerView(player: player)
            case .failed(let message):
                errorView(message) {
                    Button("Retry") { model.playLive(channel) }
                }
            default:
                // Transient while applyTab kicks in.
                Color.black
            }
        }
    }

    // MARK: - Broadcasts tab

    @ViewBuilder
    private func broadcastsContent(_ channel: ChannelInfo) -> some View {
        switch model.playback {
        case .vod(let player, let vod):
            VStack(spacing: 0) {
                HStack {
                    Button {
                        model.closePlayback()
                    } label: {
                        Label("Broadcasts", systemImage: "chevron.left")
                    }
                    Text(vod.title)
                        .font(.system(size: 12 * model.zoom))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
                Divider()
                PlayerView(player: player)
            }
        case .loading(.vod, let message):
            loadingView(message)
        case .failed(let message):
            errorView(message) {
                Button("Back") { model.closePlayback() }
            }
        default:
            VodGridView(channel: channel, history: model.watchHistory) { vod in
                model.playVod(vod)
            }
        }
    }

    // MARK: - Shared pieces

    private func loadingView(_ message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message)
                .font(.system(size: 13 * model.zoom))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    private func errorView(_ message: String, @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40 * model.zoom))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 13 * model.zoom))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40 * model.zoom))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13 * model.zoom))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
