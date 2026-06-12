import Foundation

/// A capture resolution such as 1920×1080, persisted in UserDefaults as "1920x1080".
struct CaptureResolution: Hashable, Sendable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Parses "WIDTHxHEIGHT" (case-insensitive). Nil for anything else, including
    /// the empty string used as the "default resolution" sentinel in settings.
    init?(string: String) {
        let parts = string.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              width > 0, height > 0 else { return nil }
        self.init(width: width, height: height)
    }

    /// Persisted form, e.g. "1920x1080".
    var storageString: String { "\(width)x\(height)" }

    /// Menu form, e.g. "1920 × 1080".
    var displayName: String { "\(width) × \(height)" }
}
