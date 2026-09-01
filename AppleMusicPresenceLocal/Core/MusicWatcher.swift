import Foundation
import MediaPlayer
import Observation
import UIKit

/// Observe **exclusivement** l'application Musique d'Apple.
///
/// `MPMusicPlayerController.systemMusicPlayer` est le lecteur système : sa file
/// de lecture est celle de l'app Musique. Spotify, YouTube, Deezer ou tout autre
/// lecteur tiers gèrent leur propre session audio et n'apparaissent jamais ici —
/// c'est précisément la garantie recherchée. (À ne pas confondre avec
/// `applicationMusicPlayer`, qui est une file privée à l'app, ni avec
/// `MPNowPlayingInfoCenter`, qui sert à publier et non à lire.)
@MainActor
@Observable
final class MusicWatcher {
    /// Dernier instantané observé, `nil` si l'app Musique ne joue rien.
    private(set) var current: NowPlayingTrack?
    private(set) var authorizationStatus: MPMediaLibraryAuthorizationStatus =
        MPMediaLibrary.authorizationStatus()
    private(set) var isObserving = false

    /// Appelé à chaque changement pertinent. `immediate` distingue un
    /// changement de morceau (à publier tout de suite) d'un simple rafraîchissement.
    var onUpdate: ((NowPlayingTrack?, _ immediate: Bool) -> Void)?

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Tolérance avant de considérer qu'un déplacement dans le morceau a eu lieu.
    private let seekTolerance: TimeInterval = 3

    // MARK: - Autorisation

    func requestAuthorization() async {
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        authorizationStatus = status
    }

    // MARK: - Cycle de vie

    func start() {
        guard !isObserving else { return }
        guard authorizationStatus == .authorized else { return }

        player.beginGeneratingPlaybackNotifications()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
                object: player,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.capture(immediate: true) }
            },
            center.addObserver(
                forName: .MPMusicPlayerControllerPlaybackStateDidChange,
                object: player,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.capture(immediate: true) }
            }
        ]

        // Les notifications ne couvrent ni les déplacements dans le morceau ni la
        // progression : un relevé régulier complète le tableau.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture(immediate: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        isObserving = true
        capture(immediate: true)
    }

    func stop() {
        guard isObserving else { return }

        pollTimer?.invalidate()
        pollTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        player.endGeneratingPlaybackNotifications()

        isObserving = false
        current = nil
    }

    /// Force un relevé (au retour au premier plan, par exemple).
    func refresh() {
        capture(immediate: true)
    }

    /// Récupère la pochette du morceau courant, redimensionnée pour Discord.
    func currentArtworkJPEG(maxDimension: CGFloat = 512, quality: CGFloat = 0.82) -> Data? {
        guard let artwork = player.nowPlayingItem?.artwork else { return nil }
        let size = CGSize(width: maxDimension, height: maxDimension)
        guard let image = artwork.image(at: size) else { return nil }
        return image.jpegData(compressionQuality: quality)
    }

    // MARK: - Relevé

    private func capture(immediate: Bool) {
        let snapshot = makeSnapshot()

        // Rien ne joue, et rien ne jouait : pas la peine de réveiller le réseau.
        if snapshot == nil, current == nil { return }

        if let snapshot, let previous = current {
            let changed = snapshot.differsMeaningfully(from: previous, positionTolerance: seekTolerance)
            current = snapshot
            if changed || immediate {
                onUpdate?(snapshot, immediate || !snapshot.isSameSong(as: previous))
            } else {
                // Position dans les clous : on laisse le coordinateur décider du rythme.
                onUpdate?(snapshot, false)
            }
            return
        }

        current = snapshot
        onUpdate?(snapshot, true)
    }

    private func makeSnapshot() -> NowPlayingTrack? {
        let state = mapState(player.playbackState)
        guard state != .stopped, let item = player.nowPlayingItem else { return nil }

        return NowPlayingTrack(
            item: item,
            state: state,
            position: player.currentPlaybackTime.isFinite ? player.currentPlaybackTime : 0
        )
    }

    private func mapState(_ state: MPMusicPlaybackState) -> PlaybackState {
        switch state {
        case .playing, .seekingForward, .seekingBackward:
            return .playing
        // Une interruption (appel entrant) est une pause du point de vue du profil.
        case .paused, .interrupted:
            return .paused
        case .stopped:
            return .stopped
        @unknown default:
            return .stopped
        }
    }
}
