import Foundation
import Observation

/// Journal circulaire affiché dans l'app, utile pour diagnostiquer sans Xcode.
@MainActor
@Observable
final class ActivityLog {
    enum Level: String {
        case info
        case success
        case warning
        case error

        var symbol: String {
            switch self {
            case .info: return "info.circle"
            case .success: return "checkmark.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    private(set) var entries: [Entry] = []
    private let limit = 120

    func append(_ level: Level, _ message: String) {
        entries.insert(Entry(date: Date(), level: level, message: message), at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
