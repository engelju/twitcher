import SwiftUI

/// Popover from the YouTube section's "+" button: lists the signed-in
/// user's subscriptions so they can be added to the sidebar, or offers to
/// sign in first.
struct SubscriptionPicker: View {
    @ObservedObject var model: AppModel
    @ObservedObject var account: YouTubeAccount
    @State private var search = ""
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        VStack(spacing: 0) {
            if account.isSignedIn {
                signedInContent
            } else {
                signedOutContent
            }
        }
        .frame(width: 300 * zoom, height: account.isSignedIn ? 420 * zoom : nil)
        .task(id: account.isSignedIn) {
            await account.loadSubscriptions()
        }
    }

    // MARK: - Signed out

    private var signedOutContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 32 * zoom))
                .foregroundStyle(.secondary)
            Text("Sign in to YouTube to add channels you're subscribed to.")
                .font(.system(size: 12 * zoom))
                .multilineTextAlignment(.center)
            Button("Sign In…") {
                account.showingSubscriptionPicker = false
                account.showingSignIn = true
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    // MARK: - Signed in

    private var signedInContent: some View {
        VStack(spacing: 0) {
            TextField("Search subscriptions", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12 * zoom))
                .padding(8)
            Divider()
            subscriptionList
                .frame(maxHeight: .infinity)
            Divider()
            footer
        }
    }

    @ViewBuilder
    private var subscriptionList: some View {
        switch account.subscriptions {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 12 * zoom))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await account.loadSubscriptions(force: true) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let subscriptions, let complete):
            let matches = filtered(subscriptions)
            if matches.isEmpty {
                Text(subscriptions.isEmpty ? "You're not subscribed to any channels." : "No matches.")
                    .font(.system(size: 12 * zoom))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(matches) { subscription in
                        SubscriptionRow(
                            subscription: subscription,
                            added: model.isInSidebar(subscription)
                        ) {
                            model.addYouTubeChannel(subscription)
                        }
                    }
                    if !complete {
                        Text("Some subscriptions couldn't be loaded.")
                            .font(.system(size: 10 * zoom))
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Signed in to YouTube")
                .font(.system(size: 10 * zoom))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await account.loadSubscriptions(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload subscriptions")
            Button("Sign Out") {
                Task { await account.signOut() }
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10 * zoom))
        .padding(8)
    }

    private func filtered(_ subscriptions: [YouTubeSubscription]) -> [YouTubeSubscription] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return subscriptions }
        return subscriptions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.handle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}

private struct SubscriptionRow: View {
    let subscription: YouTubeSubscription
    let added: Bool
    let onAdd: () -> Void
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: subscription.avatarURL) { image in
                image.resizable()
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 24 * zoom, height: 24 * zoom)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(subscription.title)
                    .font(.system(size: 12 * zoom, weight: .medium))
                    .lineLimit(1)
                if let handle = subscription.handle {
                    Text("@\(handle)")
                        .font(.system(size: 10 * zoom))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if added {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .help("Already in the sidebar")
            } else {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Add to sidebar")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if !added { onAdd() }
        }
    }
}
