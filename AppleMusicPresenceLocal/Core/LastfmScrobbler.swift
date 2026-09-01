import Foundation
import Observation

/// Une écoute en attente d'envoi.
struct PendingScrobble: Codable, Identifiable, Sendable {
    var id = UUID()
    var artist: String
    var track: String
    var album: String?
    var albumArtist: String?
    /// Durée en secondes.
    var duration: Int?
    /// Début de lecture, en secondes UTC — le format attendu par Last.fm.
    var timestamp: Int
    var attempts = 0
    var lastAttemptAt: Date?
}

/// Scrobbler Last.fm embarqué.
///
/// Compte le temps réellement écouté, décide si un morceau mérite d'être envoyé,
/// et conserve les écoutes sur disque tant qu'elles ne sont pas acceptées : une
/// coupure réseau ou une fermeture de l'app ne les perd pas.
@MainActor
@Observable
final class LastfmScrobbler {
    /// Écart maximal crédité entre deux relevés.
    ///
    /// Le suivi observe la lecture toutes les cinq secondes. Si le fil se rompt
    /// plus longtemps (app suspendue, interruption), on ne peut pas affirmer que la
    /// lecture a continué : mieux vaut sous-estimer que gonfler un scrobble.
    private let maxCreditedGap: TimeInterval = 90

    /// Fréquence de rafraîchissement de « en cours d'écoute » chez Last.fm.
    private let nowPlayingRefresh: TimeInterval = 120

    /// Un scrobble en échec n'est retenté qu'après ce délai.
    private let retryDelay: TimeInterval = 300

    /// Last.fm accepte jusqu'à 50 scrobbles par requête.
    private let batchSize = 50

    /// Règles historiques de Last.fm.
    var minTrackSeconds = 30
    var scrobblePercent = 50
    var scrobbleAfterSeconds = 240
    var maxAttempts = 20

    private(set) var queue: [PendingScrobble] = []
    private(set) var scrobbledThisSession = 0
    private(set) var lastError: String?
    private(set) var listeningSeconds = 0
    private(set) var currentQualifies = false

    var onLog: ((ActivityLog.Level, String) -> Void)?
    /// Appelé quand Last.fm rejette la clé : la liaison est à refaire.
    var onSessionInvalid: (() -> Void)?

    private struct Play {
        var title: String
        var artist: String
        var album: String?
        var durationMs: Int?
        /// Début de lecture (epoch), corrigé si on rejoint le morceau en cours.
        var startedAt: Date
        var listened: TimeInterval = 0
        var lastObservedAt: Date
        var lastState: PlaybackState
        var lastPositionMs: Int
        var nowPlayingSentAt: Date?
    }

    private var play: Play?
    private let client = LastfmClient()
    private var flushing = false
    private let storeURL: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("lastfm-queue.json")
        load()
    }

    // MARK: - Suivi de l'écoute

    /// Reçoit chaque relevé du lecteur. `nil` clôt l'écoute en cours.
    func observe(_ track: NowPlayingTrack?, credentials: LastfmCredentials?) {
        guard let credentials, credentials.isUsable else { return }

        guard let track else {
            if let play { finish(play, credentials: credentials) }
            play = nil
            refreshPublished()
            return
        }

        if var current = play, current.title == track.title, current.artist == track.artist,
           !looksLikeReplay(current, track) {
            creditElapsed(&current)
            current.lastState = track.state
            current.lastPositionMs = track.positionMs

            // Last.fm laisse expirer « en cours d'écoute » : on le rafraîchit.
            if track.state == .playing,
               current.nowPlayingSentAt == nil
                || Date().timeIntervalSince(current.nowPlayingSentAt!) > nowPlayingRefresh {
                current.nowPlayingSentAt = Date()
                let snapshot = current
                Task { await self.sendNowPlaying(snapshot, credentials: credentials) }
            }

            play = current
            refreshPublished()
            return
        }

        // Morceau différent (ou relancé) : on clôt le précédent avant d'ouvrir le suivant.
        if let previous = play { finish(previous, credentials: credentials) }

        var fresh = Play(
            title: track.title,
            artist: track.artist,
            album: track.album,
            durationMs: track.durationMs,
            startedAt: Date().addingTimeInterval(-Double(track.positionMs) / 1000),
            lastObservedAt: Date(),
            lastState: track.state,
            lastPositionMs: track.positionMs
        )

        if track.state == .playing {
            fresh.nowPlayingSentAt = Date()
            let snapshot = fresh
            Task { await self.sendNowPlaying(snapshot, credentials: credentials) }
        }

        play = fresh
        refreshPublished()
    }

    /// Crédite le temps écoulé depuis le dernier relevé.
    ///
    /// Indispensable aussi au moment de clore une écoute : entre le dernier relevé
    /// et le passage au morceau suivant, il s'est écoulé du temps d'écoute réel.
    private func creditElapsed(_ current: inout Play) {
        let now = Date()
        if current.lastState == .playing {
            current.listened += min(now.timeIntervalSince(current.lastObservedAt), maxCreditedGap)
        }
        current.lastObservedAt = now
    }

    /// Le morceau a-t-il été relancé depuis le début ?
    ///
    /// On était au-delà de la moitié et la position revient au tout début : c'est
    /// une réécoute, qui mérite son propre scrobble. Un simple retour en arrière
    /// manuel ne déclenche pas ce cas.
    private func looksLikeReplay(_ current: Play, _ track: NowPlayingTrack) -> Bool {
        let halfway = max(10_000, (current.durationMs ?? 0) / 2)
        return track.positionMs < 3000 && current.lastPositionMs > halfway
    }

    /// Le morceau a-t-il été écouté assez longtemps pour compter ?
    private func qualifies(_ current: Play) -> Bool {
        let durationSec = Double(current.durationMs ?? 0) / 1000

        // Last.fm refuse les morceaux trop courts.
        if durationSec > 0 && durationSec < Double(minTrackSeconds) { return false }

        // Sans durée connue, on s'en remet au seul seuil absolu.
        let threshold = durationSec > 0
            ? min(durationSec * Double(scrobblePercent) / 100, Double(scrobbleAfterSeconds))
            : Double(scrobbleAfterSeconds)

        return current.listened >= threshold
    }

    private func finish(_ play: Play, credentials: LastfmCredentials) {
        var current = play
        creditElapsed(&current)

        guard qualifies(current) else {
            onLog?(.info, "Non scrobblé (\(Int(current.listened)) s) : \(current.title)")
            return
        }

        queue.append(PendingScrobble(
            artist: current.artist,
            track: current.title,
            album: current.album,
            albumArtist: nil,
            duration: current.durationMs.map { $0 / 1000 },
            timestamp: Int(current.startedAt.timeIntervalSince1970)
        ))
        save()
        onLog?(.info, "♫ En file : \(current.title) — \(current.artist)")

        Task { await self.flush(credentials: credentials) }
    }

    private func refreshPublished() {
        listeningSeconds = Int(play?.listened ?? 0)
        currentQualifies = play.map { qualifies($0) } ?? false
    }

    // MARK: - Envois

    private func sendNowPlaying(_ play: Play, credentials: LastfmCredentials) async {
        var params: [String: String] = ["artist": play.artist, "track": play.title, "sk": credentials.sessionKey]
        if let album = play.album { params["album"] = album }
        if let duration = play.durationMs { params["duration"] = String(duration / 1000) }

        do {
            _ = try await client.call(
                method: "track.updateNowPlaying", params: params,
                keys: credentials.keys, signed: true, usePost: true
            )
            lastError = nil
        } catch {
            handle(error: error, context: "updateNowPlaying")
        }
    }

    /// Vide la file d'attente, par lots.
    func flush(credentials: LastfmCredentials) async {
        guard !flushing, credentials.isUsable else { return }
        flushing = true
        defer { flushing = false }

        // Écarte les écoutes définitivement irrécupérables.
        let abandoned = queue.filter { $0.attempts >= maxAttempts }
        if !abandoned.isEmpty {
            queue.removeAll { $0.attempts >= maxAttempts }
            onLog?(.warning, "\(abandoned.count) scrobble(s) abandonné(s) après trop d'échecs.")
            save()
        }

        let due = queue.filter { entry in
            guard let last = entry.lastAttemptAt else { return true }
            return Date().timeIntervalSince(last) >= retryDelay
        }
        guard !due.isEmpty else { return }

        let batch = Array(due.prefix(batchSize))
        var params: [String: String] = ["sk": credentials.sessionKey]

        for (index, entry) in batch.enumerated() {
            params["artist[\(index)]"] = entry.artist
            params["track[\(index)]"] = entry.track
            params["timestamp[\(index)]"] = String(entry.timestamp)
            if let album = entry.album { params["album[\(index)]"] = album }
            if let duration = entry.duration { params["duration[\(index)]"] = String(duration) }
        }

        do {
            let json = try await client.call(
                method: "track.scrobble", params: params,
                keys: credentials.keys, signed: true, usePost: true
            )

            let scrobbles = json["scrobbles"] as? [String: Any]
            let attributes = scrobbles?["@attr"] as? [String: Any]
            let accepted = attributes?["accepted"] as? Int ?? batch.count
            let ignored = attributes?["ignored"] as? Int ?? 0

            // Les scrobbles ignorés (métadonnées refusées) ne passeront jamais :
            // on les retire aussi, sinon ils bloqueraient la file indéfiniment.
            let sentIds = Set(batch.map(\.id))
            queue.removeAll { sentIds.contains($0.id) }
            save()

            scrobbledThisSession += accepted
            lastError = nil
            onLog?(.success, "\(accepted) scrobble(s) envoyé(s)\(ignored > 0 ? ", \(ignored) ignoré(s)" : "").")
        } catch {
            let failedIds = Set(batch.map(\.id))
            for index in queue.indices where failedIds.contains(queue[index].id) {
                queue[index].attempts += 1
                queue[index].lastAttemptAt = Date()
            }
            save()
            handle(error: error, context: "scrobble")
        }
    }

    private func handle(error: Error, context: String) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = "\(context) : \(message)"

        if let lastfm = error as? LastfmError, lastfm.needsRelink {
            onLog?(.error, "Clé de session Last.fm rejetée — relie le compte.")
            onSessionInvalid?()
            return
        }
        onLog?(.warning, lastError ?? message)
    }

    // MARK: - Persistance

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([PendingScrobble].self, from: data)
        else { return }
        queue = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
