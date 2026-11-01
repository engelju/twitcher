import SwiftUI

@main
struct TwitcherApp: App {
    @StateObject private var model = AppModel()

    init() {
        // When launched via `swift run` there is no app bundle, so AppKit
        // starts us as a background process. Promote to a regular app so the
        // window appears and takes focus.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("Twitcher") {
            ContentView(model: model)
                .frame(minWidth: 640, minHeight: 420)
        }
        .commands {
            CommandGroup(before: .toolbar) {
                // "+" only matches ⇧⌘=, so ContentView registers a hidden
                // ⌘= shortcut as well — both land on zoomIn().
                Button("Zoom In") { model.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { model.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { model.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            YouTubeCommands(account: model.youtubeAccount)
        }
    }
}

private struct YouTubeCommands: Commands {
    @ObservedObject var account: YouTubeAccount

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            if account.isSignedIn {
                Button("Sign Out of YouTube") {
                    Task { await account.signOut() }
                }
            } else {
                Button("Sign In to YouTube…") {
                    account.showingSignIn = true
                }
            }
        }
    }
}
