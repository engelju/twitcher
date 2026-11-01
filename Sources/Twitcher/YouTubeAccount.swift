import CryptoKit
import Foundation
import WebKit

/// A channel the signed-in user is subscribed to.
struct YouTubeSubscription: Identifiable, Hashable {
    let channelID: String
    /// Without the leading @; nil for the rare channel that has none.
    let handle: String?
    let title: String
    let avatarURL: URL?

    var id: String { channelID }

    /// What gets written to channels.json — the handle when there is one,
    /// since that's what users write by hand, else the UC… channel ID.
    var identifier: String { handle ?? channelID }
}

/// YouTube sign-in state and the signed-in user's subscriptions.
///
/// Signing in happens in a web view (`YouTubeSignInView`) backed by WebKit's
/// default data store. The session cookies are then read back out of that
/// store to make authenticated requests — no API key or OAuth client needed.
///
/// WebKit's store claims to be persistent but doesn't reliably restore
/// cookies for an unbundled executable (`swift run`), so the session is also
/// saved to a file of our own and put back into the store at launch.
@MainActor
final class YouTubeAccount: ObservableObject {
    enum SubscriptionsState {
        case idle
        case loading
        case loaded([YouTubeSubscription], complete: Bool)
        case failed(String)
    }

    @Published private(set) var isSignedIn = false
    @Published private(set) var subscriptions: SubscriptionsState = .idle
    @Published var showingSignIn = false

    private var dataStore: WKWebsiteDataStore { .default() }

    private static var sessionURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Twitcher/youtube-session.plist")
    }

    /// Updates `isSignedIn` from the cookie store. YouTube sets SAPISID on
    /// .youtube.com once the Google sign-in has redirected back.
    func checkSignIn() async {
        let signedIn = await youtubeCookies().contains { $0.name == "SAPISID" }
        if signedIn {
            await saveSession()
        }
        if signedIn != isSignedIn {
            isSignedIn = signedIn
            subscriptions = .idle
        }
    }

    /// Clears all web data: the app's web views (sign-in and the embed
    /// fallback player) only ever visit YouTube and Google.
    func signOut() async {
        await dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        try? FileManager.default.removeItem(at: Self.sessionURL)
        isSignedIn = false
        subscriptions = .idle
    }

    // MARK: - Session file

    /// Puts the saved session back into WebKit's cookie store, unless the
    /// store already has one of its own. Call before `checkSignIn()`.
    func restoreSession() async {
        guard !(await youtubeCookies().contains { $0.name == "SAPISID" }),
              let data = try? Data(contentsOf: Self.sessionURL),
              let saved = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [[String: Any]]
        else { return }
        let store = dataStore.httpCookieStore
        for properties in saved {
            let cookieProperties = Dictionary(uniqueKeysWithValues: properties.map {
                (HTTPCookiePropertyKey($0.key), $0.value)
            })
            guard let cookie = HTTPCookie(properties: cookieProperties),
                  (cookie.expiresDate ?? .distantFuture) > Date()
            else { continue }
            await store.setCookie(cookie)
        }
    }

    /// Saves the YouTube and Google cookies (the Google ones keep the web
    /// views signed in too). Readable by the current user only, like
    /// WebKit's own cookie file.
    private func saveSession() async {
        let cookies = await dataStore.httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("youtube.com") || $0.domain.contains("google.") }
        let saved = cookies.compactMap(\.properties).map { properties in
            Dictionary(uniqueKeysWithValues: properties.map { ($0.key.rawValue, $0.value) })
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
        else { return }
        let url = Self.sessionURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    func loadSubscriptions(force: Bool = false) async {
        guard isSignedIn else { return }
        switch subscriptions {
        case .loading: return
        case .loaded where !force: return
        default: break
        }
        subscriptions = .loading
        do {
            let fetcher = SubscriptionFetcher(cookies: await youtubeCookies())
            let (channels, complete) = try await fetcher.fetchAll()
            subscriptions = .loaded(channels, complete: complete)
        } catch SubscriptionFetcher.FetchError.signedOut {
            isSignedIn = false
            subscriptions = .idle
        } catch {
            subscriptions = .failed(error.localizedDescription)
        }
    }

    private func youtubeCookies() async -> [HTTPCookie] {
        await dataStore.httpCookieStore.allCookies()
            .filter { $0.domain.hasSuffix("youtube.com") }
    }
}

/// Reads the subscriptions page (`/feed/channels`) and follows its
/// continuation tokens through the innertube browse API.
private struct SubscriptionFetcher {
    enum FetchError: LocalizedError {
        case signedOut
        case badResponse

        var errorDescription: String? {
            switch self {
            case .signedOut: return "Your YouTube session has expired. Sign in again."
            case .badResponse: return "Couldn't read your subscriptions from YouTube."
            }
        }
    }

    let cookies: [HTTPCookie]

    private static let origin = "https://www.youtube.com"
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    /// Safety valve against a continuation loop; at ~100 channels per page
    /// that's still thousands of subscriptions.
    private static let maxPages = 50

    /// Returns the subscriptions in the page's order (most relevant first)
    /// and whether every page could be fetched.
    func fetchAll() async throws -> ([YouTubeSubscription], complete: Bool) {
        let html = try await fetchPage()
        guard html.contains(#""LOGGED_IN":true"#) else { throw FetchError.signedOut }
        guard let dataJSON = Self.firstMatch(#"var ytInitialData = (\{.*?\});</script>"#, in: html),
              let initialData = try? JSONSerialization.jsonObject(with: Data(dataJSON.utf8))
        else { throw FetchError.badResponse }
        let clientVersion = Self.firstMatch(#""INNERTUBE_CONTEXT_CLIENT_VERSION":"([^"]+)""#, in: html)
            ?? "2.20250101.00.00"

        var found: [YouTubeSubscription] = []
        var seen = Set<String>()
        func collect(_ json: Any) -> String? {
            var token: String?
            Self.walk(json) { key, value in
                if key == "channelRenderer", let renderer = value as? [String: Any],
                   let subscription = Self.subscription(from: renderer),
                   seen.insert(subscription.channelID).inserted {
                    found.append(subscription)
                } else if key == "continuationCommand",
                          let command = value as? [String: Any],
                          let next = command["token"] as? String {
                    token = next
                }
            }
            return token
        }

        var continuation = collect(initialData)
        var complete = true
        var pages = 0
        while let token = continuation, pages < Self.maxPages, !Task.isCancelled {
            pages += 1
            guard let page = try? await fetchContinuation(token, clientVersion: clientVersion) else {
                complete = false
                break
            }
            continuation = collect(page)
        }
        return (found, complete && continuation == nil)
    }

    // MARK: - Requests

    private func fetchPage() async throws -> String {
        var request = authorizedRequest(URL(string: "\(Self.origin)/feed/channels")!)
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8)
        else { throw FetchError.badResponse }
        return html
    }

    private func fetchContinuation(_ token: String, clientVersion: String) async throws -> Any {
        var request = authorizedRequest(URL(string: "\(Self.origin)/youtubei/v1/browse?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        if let authorization = sidAuthorization() {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB", "clientVersion": clientVersion, "hl": "en"]],
            "continuation": token,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.badResponse }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Sends the session cookies explicitly rather than through the shared
    /// cookie jar, which belongs to URLSession, not WebKit.
    private func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        let cookieHeader = cookies
            .filter { !$0.name.isEmpty }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        return request
    }

    /// Innertube API calls (unlike page loads) also need the SAPISIDHASH
    /// family of headers: SHA-1 over "timestamp SID origin" per cookie.
    private func sidAuthorization() -> String? {
        let schemes = [
            ("SAPISIDHASH", "SAPISID"),
            ("SAPISID1PHASH", "__Secure-1PAPISID"),
            ("SAPISID3PHASH", "__Secure-3PAPISID"),
        ]
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let parts = schemes.compactMap { scheme, cookieName -> String? in
            guard let sid = cookies.first(where: { $0.name == cookieName })?.value else { return nil }
            let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sid) \(Self.origin)".utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return "\(scheme) \(timestamp)_\(hex)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Parsing

    /// Visits every key/value pair in a JSON tree. YouTube nests renderers
    /// differently between the first page and continuations (and changes the
    /// layout every so often), so search rather than follow fixed paths.
    private static func walk(_ json: Any, _ visit: (String, Any) -> Void) {
        if let object = json as? [String: Any] {
            for (key, value) in object {
                visit(key, value)
                walk(value, visit)
            }
        } else if let array = json as? [Any] {
            for element in array {
                walk(element, visit)
            }
        }
    }

    private static func subscription(from renderer: [String: Any]) -> YouTubeSubscription? {
        guard let channelID = renderer["channelId"] as? String else { return nil }

        let title = (renderer["title"] as? [String: Any])?["simpleText"] as? String ?? channelID

        let canonicalURL = ((renderer["navigationEndpoint"] as? [String: Any])?["browseEndpoint"]
            as? [String: Any])?["canonicalBaseUrl"] as? String
        let handle = canonicalURL
            .flatMap { $0.removingPercentEncoding }
            .flatMap { $0.hasPrefix("/@") ? String($0.dropFirst(2)) : nil }

        // Thumbnail URLs are protocol-relative ("//yt3.ggpht.com/…").
        let thumbnails = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let avatarURL = (thumbnails?.last?["url"] as? String)
            .map { $0.hasPrefix("//") ? "https:" + $0 : $0 }
            .flatMap(URL.init(string:))

        return YouTubeSubscription(channelID: channelID, handle: handle, title: title, avatarURL: avatarURL)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        let rangeIndex = match.numberOfRanges > 1 ? 1 : 0
        guard let range = Range(match.range(at: rangeIndex), in: text) else { return nil }
        return String(text[range])
    }
}
