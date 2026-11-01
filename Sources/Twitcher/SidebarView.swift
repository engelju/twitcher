import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var account: YouTubeAccount
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        List(selection: $model.selectedChannelID) {
            let twitch = model.channels.filter { $0.platform == .twitch }
            let youtube = model.channels.filter { $0.platform == .youtube }
            if !twitch.isEmpty {
                Section("Twitch") {
                    ForEach(twitch) { channel in
                        ChannelRow(channel: channel)
                            .tag(channel.id)
                    }
                }
            }
            // Shown even without YouTube channels so "Add Channel…" is
            // reachable — but only once the list has loaded: a section that
            // gains rows on first load trips an NSTableView reentrancy warning.
            if !model.channels.isEmpty {
                Section("YouTube") {
                    ForEach(youtube) { channel in
                        ChannelRow(channel: channel)
                            .tag(channel.id)
                    }
                    addChannelRow
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("Remove from Sidebar") {
                    model.removeChannel(id: id)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Refresh live status and VODs")
                .disabled(model.isRefreshing)
            }
        }
    }

    /// Not tagged, so it's a button rather than a selectable channel.
    private var addChannelRow: some View {
        Button {
            account.showingSubscriptionPicker = true
        } label: {
            Label("Add Channel…", systemImage: "plus.circle")
                .font(.system(size: 12 * zoom))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add a channel you're subscribed to")
        .popover(isPresented: $account.showingSubscriptionPicker, arrowEdge: .trailing) {
            SubscriptionPicker(model: model, account: account)
                .environment(\.uiZoom, zoom)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                if let path = model.configPath {
                    NSWorkspace.shared.activateFileViewerSelecting([path])
                }
            } label: {
                Label("Edit channels.json", systemImage: "square.and.pencil")
                    .font(.system(size: 10 * zoom))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(model.configPath?.path ?? "")
            Spacer()
        }
        .padding(8)
        .background(.bar)
    }
}

private struct ChannelRow: View {
    let channel: ChannelInfo
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        HStack(spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(.system(size: 13 * zoom, weight: .medium))
                subtitle
            }
            Spacer()
            if channel.live != nil {
                Circle()
                    .fill(.red)
                    .frame(width: 8 * zoom, height: 8 * zoom)
            }
        }
        .padding(.vertical, 2)
    }

    private var avatar: some View {
        AsyncImage(url: channel.avatarURL) { image in
            image.resizable()
        } placeholder: {
            Circle().fill(.quaternary)
        }
        .frame(width: 28 * zoom, height: 28 * zoom)
        .clipShape(Circle())
    }

    @ViewBuilder
    private var subtitle: some View {
        if let live = channel.live {
            let parts = [
                live.game,
                live.viewers > 0 ? "\(live.viewers.formatted()) viewers" : nil,
            ].compactMap { $0 }
            Text(parts.isEmpty ? "Live" : parts.joined(separator: " · "))
                .font(.system(size: 10 * zoom))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if channel.isPlaceholder {
            Text("Loading…")
                .font(.system(size: 10 * zoom))
                .foregroundStyle(.tertiary)
        } else {
            Text("Offline")
                .font(.system(size: 10 * zoom))
                .foregroundStyle(.secondary)
        }
    }
}
