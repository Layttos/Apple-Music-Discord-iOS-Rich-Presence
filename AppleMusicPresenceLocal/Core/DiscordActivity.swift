import Foundation

/// Activité telle que Discord l'attend dans une mise à jour de présence.
struct DiscordActivity: Codable, Equatable, Sendable {
    /// 2 = « Écoute … » dans le client Discord.
    static let listeningType = 2

    struct Timestamps: Codable, Equatable, Sendable {
        /// Millisecondes epoch.
        var start: Int?
        var end: Int?
    }

    struct Assets: Codable, Equatable, Sendable {
        var largeImage: String?
        var largeText: String?
        var smallImage: String?
        var smallText: String?

        enum CodingKeys: String, CodingKey {
            case largeImage = "large_image"
            case largeText = "large_text"
            case smallImage = "small_image"
            case smallText = "small_text"
        }
    }

    var name: String
    var type: Int
    var applicationId: String?
    var details: String?
    var state: String?
    var timestamps: Timestamps?
    var assets: Assets?

    enum CodingKeys: String, CodingKey {
        case name, type, details, state, timestamps, assets
        case applicationId = "application_id"
    }

    /// Discord rejette les champs de moins de 2 ou plus de 128 caractères.
    static func clamp(_ value: String?, fallback: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.count >= 2 ? trimmed : fallback
        return text.count > 128 ? String(text.prefix(127)) + "…" : text
    }
}
