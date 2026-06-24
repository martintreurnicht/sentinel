import Foundation
import Observation

/// Drives the changelog window's load. This is the boundary where the
/// background fetch re-enters the main actor: `load()` is `@MainActor`, so
/// after `await service.fetchReleases()` suspends (running off-actor) control
/// resumes here on the main actor and `state` mutates safely — no manual hop.
@MainActor
@Observable
final class ChangelogViewModel {
    enum LoadState {
        case loading
        case loaded([Release])
        case empty
        case failed(ChangelogService.ChangelogError)
    }

    private(set) var state: LoadState = .loading
    private let service: ChangelogService

    init(service: ChangelogService = ChangelogService()) {
        self.service = service
    }

    func load() async {
        state = .loading
        do {
            let releases = try await service.fetchReleases()
            state = releases.isEmpty ? .empty : .loaded(releases)
        } catch let error as ChangelogService.ChangelogError {
            state = .failed(error)
        } catch {
            state = .failed(.transport)
        }
    }
}
