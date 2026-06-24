import Foundation
import Testing
@testable import Sentinel

struct ReleaseDecodingTests {
    /// A trimmed GitHub releases payload: a full release, a tag-only release
    /// with null name/body/date, and a pre-release (to exercise filtering).
    private static let sampleJSON = """
    [
      {
        "tag_name": "v1.7.0",
        "name": "Sentinel 1.7.0",
        "body": "- Added Keep Camera On mode\\n- Fixed a bug",
        "published_at": "2026-05-01T12:00:00Z",
        "html_url": "https://github.com/martintreurnicht/sentinel/releases/tag/v1.7.0",
        "draft": false,
        "prerelease": false
      },
      {
        "tag_name": "v1.6.0",
        "name": null,
        "body": null,
        "published_at": null,
        "html_url": "https://github.com/martintreurnicht/sentinel/releases/tag/v1.6.0",
        "draft": false,
        "prerelease": false
      },
      {
        "tag_name": "v2.0.0-beta.1",
        "name": "Sentinel 2.0 Beta",
        "body": "Beta build",
        "published_at": "2026-06-01T00:00:00Z",
        "html_url": "https://github.com/martintreurnicht/sentinel/releases/tag/v2.0.0-beta.1",
        "draft": false,
        "prerelease": true
      }
    ]
    """

    private func decodeSample() throws -> [Release] {
        let data = try #require(Self.sampleJSON.data(using: .utf8))
        return try ChangelogService.decodeReleases(from: data)
    }

    @Test func decodesCoreFields() throws {
        let releases = try decodeSample()
        #expect(releases.count == 3)
        let first = try #require(releases.first)
        #expect(first.tagName == "v1.7.0")
        #expect(first.name == "Sentinel 1.7.0")
        #expect(first.displayTitle == "Sentinel 1.7.0")
        #expect(first.draft == false)
        #expect(first.prerelease == false)
        #expect(first.body?.contains("Keep Camera On") == true)
        #expect(first.htmlURL.absoluteString.hasSuffix("/releases/tag/v1.7.0"))
    }

    @Test func parsesPublishedDate() throws {
        let first = try #require(try decodeSample().first)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-05-01T12:00:00Z"))
        #expect(first.publishedAt == expected)
    }

    @Test func toleratesNullNameBodyAndDate() throws {
        // The second entry has null name/body/published_at — must decode, not throw.
        let tagOnly = try #require(try decodeSample().dropFirst().first)
        #expect(tagOnly.name == nil)
        #expect(tagOnly.body == nil)
        #expect(tagOnly.publishedAt == nil)
        #expect(tagOnly.displayTitle == "v1.6.0") // falls back to the tag
    }

    @Test func visibleReleasesDropsDraftsAndPrereleases() throws {
        let url = try #require(URL(string: "https://example.com"))
        let releases = [
            release("v3", url: url),
            release("beta", url: url, prerelease: true),
            release("draft", url: url, draft: true),
            release("v2", url: url),
        ]
        #expect(ChangelogService.visibleReleases(from: releases).map(\.tagName) == ["v3", "v2"])
    }

    @Test func visibleReleasesCapsAtMax() throws {
        let url = try #require(URL(string: "https://example.com"))
        let releases = (1...15).map { release("v\($0)", url: url) }
        #expect(ChangelogService.visibleReleases(from: releases).count == ChangelogService.maxReleases)
    }

    private func release(_ tag: String, url: URL, draft: Bool = false, prerelease: Bool = false) -> Release {
        Release(
            tagName: tag, name: nil, body: nil, publishedAt: nil,
            htmlURL: url, draft: draft, prerelease: prerelease
        )
    }
}
