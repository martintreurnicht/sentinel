import Foundation

/// One published release, decoded from the GitHub Releases REST API. A value
/// type so it can cross the actor boundary from the background fetch back to
/// the main actor without a data race.
struct Release: Decodable, Sendable, Identifiable, Equatable {
    let tagName: String
    let name: String?
    let body: String?
    let publishedAt: Date?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case publishedAt = "published_at"
        case htmlURL = "html_url"
        case draft
        case prerelease
    }

    /// The tag is unique per repository, so it is a stable identity for SwiftUI
    /// lists — unlike an array index, which shifts as releases are added.
    var id: String { tagName }

    /// Prefer the human-written release name; fall back to the tag when GitHub
    /// returns a null or empty name (common for tag-only releases).
    var displayTitle: String {
        if let name, !name.isEmpty { return name }
        return tagName
    }
}
