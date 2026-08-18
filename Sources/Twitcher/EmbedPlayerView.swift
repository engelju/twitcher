import SwiftUI
import WebKit

/// Fallback player for YouTube when yt-dlp isn't available: the official
/// embed player in a web view. Playback works out of the box, but there's
/// no PiP button or watch-progress tracking, and ads may play.
struct EmbedPlayerView: NSViewRepresentable {
    let videoID: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(
            url: URL(string: "https://www.youtube.com/embed/\(videoID)?autoplay=1&playsinline=1")!
        ))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
