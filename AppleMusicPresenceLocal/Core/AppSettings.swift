import Foundation
import Observation

/// Identifiants Last.fm, réunis pour être passés d'un coup au scrobbler.
struct LastfmCredentials: Sendable {
    var apiKey: String
    var apiSecret: String
    var sessionKey: String

    /// Tout est là pour scrobbler ?
    var isUsable: Bool { !apiKey.isEmpty && !apiSecret.isEmpty && !sessionKey.isEmpty }

    var keys: LastfmAPIKeys { LastfmAPIKeys(key: apiKey, secret: apiSecret) }
}

/// Réglages persistés.
///
/// Les secrets — token Discord, clés Last.fm — vivent dans le trousseau ; le reste
/// dans les préférences.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let applicationId = "discordApplicationId"
        static let activityName = "activityName"
        static let status = "discordStatus"
        static let enabled = "presenceEnabled"
        static let showWhenPaused = "showWhenPaused"
        static let lastfmEnabled = "lastfmEnabled"
        static let lastfmUsername = "lastfmUsername"
        static let pendingLastfmToken = "pendingLastfmToken"

        // Trousseau
        static let discordToken = "discordUserToken"
        static let lastfmApiKey = "lastfmApiKey"
        static let lastfmApiSecret = "lastfmApiSecret"
        static let lastfmSessionKey = "lastfmSessionKey"
    }

    private let defaults = UserDefaults.standard

    /// Application Discord dont le nom et l'icône habillent l'activité.
    var applicationId: String {
        didSet { defaults.set(applicationId, forKey: Key.applicationId) }
    }

    /// Texte affiché après « Écoute … ».
    var activityName: String {
        didSet { defaults.set(activityName, forKey: Key.activityName) }
    }

    /// online, idle, dnd ou invisible.
    var status: String {
        didSet { defaults.set(status, forKey: Key.status) }
    }

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    /// Garder la présence affichée quand la lecture est en pause.
    var showWhenPaused: Bool {
        didSet { defaults.set(showWhenPaused, forKey: Key.showWhenPaused) }
    }

    var lastfmEnabled: Bool {
        didSet { defaults.set(lastfmEnabled, forKey: Key.lastfmEnabled) }
    }

    var lastfmUsername: String {
        didSet { defaults.set(lastfmUsername, forKey: Key.lastfmUsername) }
    }

    /// Jeton d'autorisation Last.fm en attente de finalisation.
    var pendingLastfmToken: String {
        didSet { defaults.set(pendingLastfmToken, forKey: Key.pendingLastfmToken) }
    }

    // MARK: - Secrets

    var discordToken: String {
        didSet { store(discordToken, at: Key.discordToken) }
    }

    var lastfmApiKey: String {
        didSet { store(lastfmApiKey, at: Key.lastfmApiKey) }
    }

    var lastfmApiSecret: String {
        didSet { store(lastfmApiSecret, at: Key.lastfmApiSecret) }
    }

    var lastfmSessionKey: String {
        didSet { store(lastfmSessionKey, at: Key.lastfmSessionKey) }
    }

    private func store(_ value: String, at key: String) {
        if value.isEmpty {
            Keychain.remove(key)
        } else {
            Keychain.set(value, for: key)
        }
    }

    private init() {
        defaults.register(defaults: [
            Key.activityName: "Apple Music",
            Key.status: "online",
            Key.enabled: true,
            Key.showWhenPaused: true,
            Key.lastfmEnabled: false
        ])

        applicationId = defaults.string(forKey: Key.applicationId) ?? ""
        activityName = defaults.string(forKey: Key.activityName) ?? "Apple Music"
        status = defaults.string(forKey: Key.status) ?? "online"
        isEnabled = defaults.bool(forKey: Key.enabled)
        showWhenPaused = defaults.bool(forKey: Key.showWhenPaused)
        lastfmEnabled = defaults.bool(forKey: Key.lastfmEnabled)
        lastfmUsername = defaults.string(forKey: Key.lastfmUsername) ?? ""
        pendingLastfmToken = defaults.string(forKey: Key.pendingLastfmToken) ?? ""

        discordToken = Keychain.get(Key.discordToken) ?? ""
        lastfmApiKey = Keychain.get(Key.lastfmApiKey) ?? ""
        lastfmApiSecret = Keychain.get(Key.lastfmApiSecret) ?? ""
        lastfmSessionKey = Keychain.get(Key.lastfmSessionKey) ?? ""
    }

    /// De quoi ouvrir une session Discord ?
    var isConfigured: Bool {
        !discordToken.isEmpty && !applicationId.isEmpty
    }

    var lastfmCredentials: LastfmCredentials? {
        guard lastfmEnabled else { return nil }
        return LastfmCredentials(
            apiKey: lastfmApiKey,
            apiSecret: lastfmApiSecret,
            sessionKey: lastfmSessionKey
        )
    }

    var isLastfmLinked: Bool {
        !lastfmSessionKey.isEmpty
    }
}
