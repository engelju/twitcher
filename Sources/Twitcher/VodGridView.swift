import SwiftUI

/// Grid of a channel's recent broadcasts, shown in the Broadcasts tab
/// (available whether the channel is live or offline).
struct VodGridView: View {
    let channel: ChannelInfo
    @ObservedObject var history: WatchProgressStore
    let onSelect: (VodInfo) -> Void
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if channel.vods.isEmpty {
                    Text(channel.isPlaceholder ? "Loading…" : "No recent broadcasts.")
                        .font(.system(size: 13 * zoom))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220 * zoom, maximum: 320 * zoom), spacing: 16)],
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(channel.vods) { vod in
                            Button {
                                onSelect(vod)
                            } label: {
                                VodCard(vod: vod, progress: history.progress(for: vod.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(channel.displayName)
                    .font(.system(size: 17 * zoom, weight: .bold))
                if channel.live != nil {
                    Text("Live")
                        .font(.system(size: 10 * zoom, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                } else {
                    Text("Offline")
                        .font(.system(size: 10 * zoom, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            Text("Recent broadcasts")
                .font(.system(size: 13 * zoom))
                .foregroundStyle(.secondary)
        }
    }
}

private struct VodCard: View {
    let vod: VodInfo
    let progress: WatchProgress?
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
            Text(vod.title)
                .font(.system(size: 12 * zoom, weight: .medium))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            Text([vod.game, vod.formattedAge].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10 * zoom))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        AsyncImage(url: vod.thumbnailURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.quaternary)
                .overlay {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .bottom) {
            if let progress, !progress.finished, progress.fraction > 0.02 {
                GeometryReader { geo in
                    Rectangle()
                        .fill(.red)
                        .frame(width: geo.size.width * progress.fraction)
                }
                .frame(height: 3)
                .background(.white.opacity(0.3))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) {
            Text(vod.formattedLength)
                .font(.system(size: 9 * zoom, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                .padding(5)
        }
        .overlay(alignment: .topTrailing) {
            if progress?.finished == true {
                Label("Watched", systemImage: "checkmark")
                    .font(.system(size: 9 * zoom, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(5)
            }
        }
    }
}
