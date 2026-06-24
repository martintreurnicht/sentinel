import SwiftUI

/// The "What's New" window contents: the last few stable releases with their
/// notes, plus a button to the full history on GitHub. Hosted in an `NSWindow`
/// by `ChangelogWindowController`. The fetch runs once via `.task` and is
/// cancelled automatically if the window closes mid-load.
struct ChangelogView: View {
    @State private var viewModel = ChangelogViewModel()

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 560)
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView("Loading changelog…")
        case .loaded(let releases):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(releases) { ReleaseSection(release: $0) }
                }
                .padding(20)
            }
        case .empty:
            statusMessage(symbol: "doc.plaintext", text: "No releases yet.")
        case .failed(let error):
            VStack(spacing: 12) {
                statusMessage(symbol: "exclamationmark.triangle", text: Self.errorMessage(for: error))
                Button("Retry") { Task { await viewModel.load() } }
            }
        }
    }

    /// Always present, so even the error and empty states keep a working path
    /// to the releases on GitHub.
    private var footer: some View {
        HStack {
            Spacer()
            if let url = ChangelogService.releasesPageURL {
                Link("View Full History on GitHub", destination: url)
            }
        }
        .padding(12)
    }

    private func statusMessage(symbol: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private static func errorMessage(for error: ChangelogService.ChangelogError) -> String {
        switch error {
        case .rateLimited:
            return "GitHub's rate limit was reached. Try again later, or view the history on GitHub."
        case .transport:
            return "Couldn't reach GitHub. Check your connection and try again."
        case .http, .decoding:
            return "Couldn't load the changelog. Try again, or view the history on GitHub."
        }
    }
}

/// One release: version and date header, then the notes rendered from Markdown.
private struct ReleaseSection: View {
    let release: Release

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(release.displayTitle)
                    .font(.headline)
                if let date = release.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let body = release.body, !body.isEmpty {
                Text(Self.formattedNotes(body))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Renders the notes' Markdown, preserving line breaks so each "- item"
    /// stays on its own line while inline markup (bold, links) is styled.
    /// Falls back to the raw text if parsing fails.
    private static func formattedNotes(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
