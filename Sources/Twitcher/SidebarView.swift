import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
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
                    .onMove { move(twitch, from: $0, to: $1) }
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
                    .onMove { move(youtube, from: $0, to: $1) }
                    addChannelRow
                        .tag(AppModel.subscriptionsPageID)
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, id != AppModel.subscriptionsPageID {
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

    /// Selecting it opens the subscriptions page in the main area.
    private var addChannelRow: some View {
        Label("Add Channel…", systemImage: "plus.circle")
            .font(.system(size: 12 * zoom))
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
            .help("Add a channel you're subscribed to")
    }

    private func move(_ section: [ChannelInfo], from source: IndexSet, to destination: Int) {
        var ids = section.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        model.reorderChannels(ids)
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
