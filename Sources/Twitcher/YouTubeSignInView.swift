import SwiftUI
import WebKit

/// Google's sign-in page in a web view. Finishes once Google has redirected
/// back to youtube.com and the session cookie is in place.
struct YouTubeSignInView: View {
    @ObservedObject var account: YouTubeAccount
    @Environment(\.dismiss) private var dismiss

    private static let signInURL = URL(string:
        "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3D%252F"
    )!

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to YouTube")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            SignInWebView(url: Self.signInURL) { url in
                guard url.host == "www.youtube.com" else { return }
                Task {
                    await account.checkSignIn()
                    if account.isSignedIn {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 480, height: 640)
    }
}

private struct SignInWebView: NSViewRepresentable {
    let url: URL
    let onPageLoaded: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageLoaded: onPageLoaded)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Google refuses sign-in from user agents it doesn't recognize as a
        // browser, which includes WKWebView's default one.
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onPageLoaded: (URL) -> Void

        init(onPageLoaded: @escaping (URL) -> Void) {
            self.onPageLoaded = onPageLoaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url {
                onPageLoaded(url)
            }
        }
    }
}
