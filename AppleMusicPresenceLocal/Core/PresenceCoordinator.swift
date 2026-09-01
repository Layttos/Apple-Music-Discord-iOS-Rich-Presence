import Foundation
import Observation
import UIKit

/// Relie l'app Musique à Discord et à Last.fm, sans serveur intermédiaire.
@MainActor
@Observable
final class PresenceCoordinator {
    let watcher = MusicWatcher()
    let keepAlive = BackgroundKeepAlive()
    let gateway = DiscordGateway()
    let scrobbler = LastfmScrobbler()
    let log = ActivityLog()

    private(set) var isActive = false
    private(set) var lastPushedAt: Date?

    private let artwork = ArtworkResolver()
    private let settings = AppSettings.shared
    private let lastfmClient = LastfmClient()

    /// Garde-fou anti-rafale entre deux mises à jour de présence.
    private let minimumInterval: TimeInterval = 3
    /// Écart de position au-delà duquel on renvoie les timestamps.
    private let seekTolerance: TimeInterval = 4
    /// Temps maximal accordé à la recherche de pochette avant de publier sans elle.
    private let artworkBudget: TimeInterval = 4

    private var pending: NowPlayingTrack?
    private var lastSent: NowPlayingTrack?
    private var lastAttemptAt: Date?
    private var pushTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var flushTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []

    // MARK: - Cycle de vie

    func bootstrap() async {
        registerLifecycleObservers()
        wireCallbacks()

        if watcher.authorizationStatus != .authorized {
            await watcher.requestAuthorization()
        }
        guard watcher.authorizationStatus == .authorized else {
            log.append(.error, "Accès à la médiathèque refusé — la lecture ne peut pas être suivie.")
            return
        }

        watcher.onUpdate = { [weak self] track, immediate in
            self?.handle(track: track, immediate: immediate)
        }

        if settings.isEnabled { start() }
    }

    private func wireCallbacks() {
        gateway.onLog = { [weak self] level, message in
            self?.log.append(level, message)
        }
        scrobbler.onLog = { [weak self] level, message in
            self?.log.append(level, message)
        }
        let log = log
        Task {
            await artwork.setLogger { level, message in
                Task { @MainActor in log.append(level, message) }
            }
        }
        scrobbler.onSessionInvalid = { [weak self] in
            // La clé ne vaut plus rien : on la retire pour que l'UI propose de relier.
            self?.settings.lastfmSessionKey = ""
        }
    }

    func start() {
        guard !isActive else { return }
        guard settings.isConfigured else {
            log.append(.warning, "Renseigne le token Discord et l'identifiant d'application avant d'activer.")
            return
        }

        keepAlive.start()
        watcher.start()
        gateway.connect(
            token: settings.discordToken,
            applicationId: settings.applicationId,
            status: settings.status
        )
        startScrobbleFlush()

        isActive = true
        log.append(.success, "Suivi actif — application Musique.")
        if let issue = keepAlive.lastIssue { log.append(.warning, issue) }
    }

    func stop() {
        guard isActive else { return }

        flushTimer?.invalidate()
        flushTimer = nil
        pushTask?.cancel()
        pushTask = nil
        artworkTask?.cancel()
        artworkTask = nil

        // Clôt l'écoute en cours : elle sera scrobblée si elle le mérite.
        scrobbler.observe(nil, credentials: settings.lastfmCredentials)
        watcher.stop()
        keepAlive.stop()

        let gateway = gateway
        Task { await gateway.disconnect() }

        isActive = false
        pending = nil
        lastSent = nil
        log.append(.info, "Suivi arrêté.")
    }

    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        if enabled { start() } else { stop() }
    }

    /// Reprend la connexion avec des réglages fraîchement modifiés.
    func reload() {
        guard isActive else {
            if settings.isEnabled { start() }
            return
        }
        stop()
        if settings.isEnabled { start() }
    }

    // MARK: - Décision de mise à jour

    private func handle(track: NowPlayingTrack?, immediate: Bool) {
        guard isActive else { return }

        // Le scrobbler suit chaque relevé, même ceux qui ne valent pas une mise à
        // jour de présence : c'est ce qui lui permet de compter le temps d'écoute.
        scrobbler.observe(track, credentials: settings.lastfmCredentials)

        guard let track else {
            if lastSent != nil {
                lastSent = nil
                pending = nil
                gateway.setActivity(nil)
                log.append(.info, "Présence effacée.")
            }
            return
        }

        pending = track
        if immediate || shouldPush(track) { schedulePush() }
    }

    private func shouldPush(_ track: NowPlayingTrack) -> Bool {
        guard let lastSent else { return true }
        return track.differsMeaningfully(from: lastSent, positionTolerance: seekTolerance)
    }

    private func schedulePush() {
        guard pushTask == nil else { return }
        let wait = max(0, minimumInterval - Date().timeIntervalSince(lastAttemptAt ?? .distantPast))

        pushTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            await self?.push()
            self?.pushTask = nil
            self?.pushIfPendingChanged()
        }
    }

    /// Relance si un relevé est arrivé pendant la mise à jour précédente.
    private func pushIfPendingChanged() {
        guard isActive, let pending else { return }
        guard let lastSent else { return schedulePush() }
        if pending.differsMeaningfully(from: lastSent, positionTolerance: seekTolerance) {
            schedulePush()
        }
    }

    private func push() async {
        guard let track = pending else { return }
        lastAttemptAt = Date()

        let visible = track.state == .playing || (track.state == .paused && settings.showWhenPaused)
        guard visible else {
            gateway.setActivity(nil)
            lastSent = track
            return
        }

        // La présence est posée d'un seul tenant, pochette comprise : voir un
        // asset vide se remplacer une seconde plus tard est plus disgracieux
        // qu'un court délai. Le plafond évite de retomber dans l'attente sans fin
        // quand le réseau traîne.
        let image = await artworkWithinBudget(for: track)
        gateway.setActivity(buildActivity(for: track, image: image))

        if lastSent.map({ !track.isSameSong(as: $0) }) ?? true {
            log.append(.info, "▶ \(track.title) — \(track.artist)")
        }
        lastSent = track
        lastPushedAt = Date()

        // Résolution trop lente : on complètera dès qu'elle aboutit.
        if image == nil { completeArtworkLater(for: track) }
    }

    /// Pochette du morceau, en s'accordant au plus `artworkBudget` secondes.
    ///
    /// Une image déjà connue revient immédiatement — c'est le cas courant, le
    /// cache survivant aux redémarrages.
    private func artworkWithinBudget(for track: NowPlayingTrack) async -> String? {
        if let cached = await artwork.cachedImage(for: track) { return cached }

        let resolver = artwork
        let token = settings.discordToken
        let applicationId = settings.applicationId
        let budget = artworkBudget

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await resolver.resolve(track: track, discordToken: token, applicationId: applicationId)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(budget))
                return nil
            }

            let first = await group.next()
            group.cancelAll()
            return first.flatMap { $0 }
        }
    }

    /// Termine une résolution qui a dépassé le budget, puis complète la présence.
    private func completeArtworkLater(for track: NowPlayingTrack) {
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let self else { return }

            let image = await self.artwork.resolve(
                track: track,
                discordToken: self.settings.discordToken,
                applicationId: self.settings.applicationId
            )

            // Le morceau a pu changer pendant la recherche : ne pas écraser
            // l'activité en cours avec la pochette de la précédente.
            guard let image,
                  let current = self.lastSent,
                  current.isSameSong(as: track)
            else { return }

            self.gateway.setActivity(self.buildActivity(for: current, image: image))
        }
    }

    private func buildActivity(for track: NowPlayingTrack, image: String?) -> DiscordActivity {
        var activity = DiscordActivity(
            name: settings.activityName,
            type: DiscordActivity.listeningType,
            applicationId: settings.applicationId,
            details: DiscordActivity.clamp(track.title, fallback: "Morceau inconnu"),
            state: DiscordActivity.clamp(
                track.state == .paused ? "⏸ \(track.artist)" : track.artist,
                fallback: "Artiste inconnu"
            )
        )

        // En pause, un compteur qui court n'aurait aucun sens.
        if track.state == .playing, let duration = track.durationMs {
            let start = Int(Date().timeIntervalSince1970 * 1000) - track.positionMs
            activity.timestamps = .init(start: start, end: start + duration)
        }

        if let image {
            activity.assets = .init(
                largeImage: image,
                largeText: DiscordActivity.clamp(track.album ?? track.title, fallback: settings.activityName)
            )
        }

        return activity
    }

    // MARK: - Last.fm

    /// Étape 1 : demande un jeton et renvoie l'URL d'autorisation à ouvrir.
    func beginLastfmLink() async -> URL? {
        let keys = LastfmAPIKeys(key: settings.lastfmApiKey, secret: settings.lastfmApiSecret)
        guard !keys.isEmpty else {
            log.append(.warning, "Renseigne la clé et le secret d'API Last.fm d'abord.")
            return nil
        }

        do {
            let token = try await lastfmClient.requestToken(keys: keys)
            settings.pendingLastfmToken = token
            return LastfmClient.authorizeURL(apiKey: keys.key, token: token)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.append(.error, "Last.fm : \(message)")
            return nil
        }
    }

    /// Étape 2 : échange le jeton autorisé contre une clé de session.
    @discardableResult
    func finishLastfmLink() async -> Bool {
        let token = settings.pendingLastfmToken
        guard !token.isEmpty else { return false }

        do {
            let session = try await lastfmClient.createSession(
                token: token,
                keys: LastfmAPIKeys(key: settings.lastfmApiKey, secret: settings.lastfmApiSecret)
            )
            settings.lastfmSessionKey = session.key
            settings.lastfmUsername = session.username
            settings.pendingLastfmToken = ""
            log.append(.success, "Last.fm lié : \(session.username)")

            if let credentials = settings.lastfmCredentials {
                await scrobbler.flush(credentials: credentials)
            }
            return true
        } catch {
            // Tant que l'utilisateur n'a pas cliqué « Autoriser », l'échec est normal.
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.append(.warning, "Last.fm pas encore autorisé (\(message)).")
            return false
        }
    }

    func unlinkLastfm() {
        settings.lastfmSessionKey = ""
        settings.lastfmUsername = ""
        settings.pendingLastfmToken = ""
        log.append(.info, "Compte Last.fm délié.")
    }

    /// Réessaie régulièrement d'envoyer les écoutes en attente.
    private func startScrobbleFlush() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let credentials = self.settings.lastfmCredentials else { return }
                Task { await self.scrobbler.flush(credentials: credentials) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    // MARK: - Retours au premier plan

    private func registerLifecycleObservers() {
        let center = NotificationCenter.default

        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.isActive { self.watcher.refresh() }

                    // De retour de Safari après une autorisation Last.fm : on tente
                    // de finaliser sans rien demander à l'utilisateur.
                    if !self.settings.pendingLastfmToken.isEmpty, !self.settings.isLastfmLinked {
                        Task { await self.finishLastfmLink() }
                    }
                }
            }
        )

        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive, !self.keepAlive.isRunning else { return }
                    self.keepAlive.start()
                }
            }
        )
    }
}
