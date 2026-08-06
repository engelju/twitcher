import Foundation

/// Minimal client for Twitch's (unofficial) GraphQL endpoint.
struct GQLClient {
    /// Public client ID used by the Twitch web player.
    static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    private static let endpoint = URL(string: "https://gql.twitch.tv/gql")!

    struct HTTPError: LocalizedError {
        let statusCode: Int
        var errorDescription: String? { "Twitch GQL returned HTTP \(statusCode)." }
    }

    func post(operationName: String? = nil,
              query: String,
              variables: [String: Any] = [:]) async throws -> Data {
        var body: [String: Any] = ["query": query, "variables": variables]
        if let operationName {
            body["operationName"] = operationName
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(Self.clientID, forHTTPHeaderField: "Client-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HTTPError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }
}
