import Foundation

/// Fetches the most recent releases from the GitHub REST API. Stateless and
/// `Sendable`, so it can be created on demand and called from any context.
/// `fetchReleases()` is async and not main-actor bound, so the network request
/// and JSON decode run off the main actor; it returns a `Sendable` `[Release]`
/// the caller hands back to the UI.
struct ChangelogService: Sendable {
    /// How `fetchReleases()` can fail. The UI maps each case to a message.
    enum ChangelogError: Error, Equatable {
        case rateLimited
        case http(Int)
        case transport
        case decoding
    }

    /// At most this many releases are shown — the changelog is "last 5 versions".
    static let maxReleases = 5

    /// The releases page, for the "View Full History" button and as the fallback
    /// when the API is unreachable. Optional only because `URL(string:)` is
    /// failable; this literal is always valid.
    static let releasesPageURL = URL(string: "https://github.com/martintreurnicht/sentinel/releases")

    private let owner = "martintreurnicht"
    private let repo = "sentinel"

    func fetchReleases() async throws -> [Release] {
        let endpoint = "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=\(Self.maxReleases)"
        guard let url = URL(string: endpoint) else { throw ChangelogError.transport }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests with no User-Agent (403), so always send one.
        request.setValue("Sentinel-macOS", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ChangelogError.transport
        }

        if let error = Self.statusError(for: response) { throw error }

        do {
            let releases = try Self.decodeReleases(from: data)
            return Self.visibleReleases(from: releases)
        } catch {
            throw ChangelogError.decoding
        }
    }

    /// Decodes a GitHub releases JSON payload. Exposed so tests exercise the
    /// exact decoding path `fetchReleases()` uses.
    static func decodeReleases(from data: Data) throws -> [Release] {
        try makeDecoder().decode([Release].self, from: data)
    }

    /// Stable releases only (no drafts or pre-releases), preserving the API's
    /// newest-first order and the 10-item cap. Pure, so it is unit-tested
    /// without touching the network.
    static func visibleReleases(from releases: [Release]) -> [Release] {
        Array(releases.filter { !$0.draft && !$0.prerelease }.prefix(maxReleases))
    }

    /// Maps a non-success response to an error, distinguishing an exhausted rate
    /// limit (403/429 with no remaining quota) from other server failures.
    private static func statusError(for response: URLResponse) -> ChangelogError? {
        guard let http = response as? HTTPURLResponse else { return .transport }
        switch http.statusCode {
        case 200...299:
            return nil
        case 403, 429:
            let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
            return remaining == "0" ? .rateLimited : .http(http.statusCode)
        default:
            return .http(http.statusCode)
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
