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
        .onChange(of: model.selectedChannelID) {
            model.selectionChanged()
        }
        .onChange(of: model.detailTab) {
            model.applyTab()
        }
    }
}

struct DetailView: View {
    @ObservedObject var model: AppModel

    /// Chat only exists for Twitch content, so the pane auto-hides on
    /// YouTube channels (the user's show/hide preference is untouched).
    private var chatSupported: Bool {
        model.selectedChannel?.platform != .youtube
    }

    var body: some View {
        HStack(spacing: 0) {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.showChat && chatSupported {
                Divider()
                ChatPane(chat: model.chat, replay: model.chatReplay)
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
            if !model.qualities.isEmpty {
                ToolbarItem {
                    qualityMenu
                }
            }
            ToolbarItem {
                Toggle(isOn: $model.showChat.animation(.easeInOut(duration: 0.15))) {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .help(chatSupported
                    ? (model.showChat ? "Hide chat" : "Show chat")
                    : "Chat is not available for YouTube channels")
                .disabled(!chatSupported)
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
            case .live(let backend, _):
                playerView(backend)
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
        case .vod(let backend, let vod):
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
                playerView(backend)
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

    /// Shows the rendition actually playing, so "Best" reads as e.g. 1080p60.
    private var qualityLabel: String {
        if model.preference == .auto { return "Auto" }
        return model.selectedQuality?.label ?? "Best"
    }

    private var qualityMenu: some View {
        Menu {
            Button {
                model.selectQuality(.best)
            } label: {
                Label("Best available", systemImage: model.preference == .best ? "checkmark" : "")
            }
            Button {
                model.selectQuality(.auto)
            } label: {
                Label("Auto (adapts to connection)",
                      systemImage: model.preference == .auto ? "checkmark" : "")
            }
            Divider()
            ForEach(model.qualities) { variant in
                Button {
                    model.selectQuality(.height(variant.height))
                } label: {
                    Label(
                        variant.label,
                        systemImage: model.preference == .height(variant.height) ? "checkmark" : ""
                    )
                }
            }
        } label: {
            Label(qualityLabel, systemImage: "slider.horizontal.3")
        }
        .help("Video quality")
    }

    // MARK: - Shared pieces

    @ViewBuilder
    private func playerView(_ backend: AppModel.PlayerBackend) -> some View {
        switch backend {
        case .native(let player):
            VStack(spacing: 0) {
                PlayerView(player: player)
                if let note = model.qualityNote {
                    Text(note)
                        .font(.system(size: 10 * model.zoom))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(4)
                        .background(.bar)
                }
            }
        case .embed(let videoID):
            VStack(spacing: 0) {
                EmbedPlayerView(videoID: videoID)
                Divider()
                Text("Embedded YouTube player — install yt-dlp (brew install yt-dlp) for native playback with resume support.")
                    .font(.system(size: 10 * model.zoom))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(4)
                    .background(.bar)
            }
        }
    }

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
