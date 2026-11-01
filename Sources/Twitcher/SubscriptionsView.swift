import SwiftUI

/// Main-screen page behind the sidebar's "Add Channel…" item: a grid of the
/// signed-in user's YouTube subscriptions, each addable to the sidebar.
struct SubscriptionsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var account: YouTubeAccount
    @State private var search = ""
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        Group {
            if account.isSignedIn {
                signedInContent
            } else {
                signedOutContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: account.isSignedIn) {
            await account.loadSubscriptions()
        }
    }

    // MARK: - Signed out

    private var signedOutContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 40 * zoom))
                .foregroundStyle(.secondary)
            Text("Sign in to YouTube to add channels you're subscribed to.")
                .font(.system(size: 13 * zoom))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Sign In…") {
                account.showingSignIn = true
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Signed in

    private var signedInContent: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            switch account.subscriptions {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message)
                        .font(.system(size: 13 * zoom))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    Button("Retry") {
                        Task { await account.loadSubscriptions(force: true) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let subscriptions, let complete):
                grid(subscriptions, complete: complete)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Subscriptions")
                    .font(.system(size: 17 * zoom, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13 * zoom))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200 * zoom)
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
    }

    private var subtitle: String {
        if case .loaded(let subscriptions, _) = account.subscriptions {
            return "\(subscriptions.count) channels — add any of them to the sidebar."
        }
        return "Add any of them to the sidebar."
    }

    @ViewBuilder
    private func grid(_ subscriptions: [YouTubeSubscription], complete: Bool) -> some View {
        let matches = filtered(subscriptions)
        if matches.isEmpty {
            Text(subscriptions.isEmpty ? "You're not subscribed to any channels." : "No matches.")
                .font(.system(size: 13 * zoom))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150 * zoom, maximum: 220 * zoom), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(matches) { subscription in
                            SubscriptionCard(
                                subscription: subscription,
                                added: model.isInSidebar(subscription)
                            ) {
                                model.addYouTubeChannel(subscription)
                            }
                        }
                    }
                    if !complete {
                        Text("Some subscriptions couldn't be loaded. Reload to try again.")
                            .font(.system(size: 11 * zoom))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
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

private struct SubscriptionCard: View {
    let subscription: YouTubeSubscription
    let added: Bool
    let onAdd: () -> Void
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        VStack(spacing: 6) {
            AsyncImage(url: subscription.avatarURL) { image in
                image.resizable()
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 72 * zoom, height: 72 * zoom)
            .clipShape(Circle())
            Text(subscription.title)
                .font(.system(size: 12 * zoom, weight: .medium))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
            Text(subscription.handle.map { "@\($0)" } ?? " ")
                .font(.system(size: 10 * zoom))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if added {
                Label("In Sidebar", systemImage: "checkmark")
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.secondary)
                    .frame(height: 22 * zoom)
            } else {
                Button(action: onAdd) {
                    Label("Add to Sidebar", systemImage: "plus")
                        .font(.system(size: 11 * zoom))
                }
                .controlSize(.small)
                .frame(height: 22 * zoom)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
