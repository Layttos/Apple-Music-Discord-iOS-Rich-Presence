import CryptoKit
import Foundation
import MediaPlayer

/// État de lecture, tel qu'il est transmis au serveur.
enum PlaybackState: String, Codable, Sendable {
    case playing
    case paused
    case stopped
}

/// Instantané de ce que joue l'application Musique.
struct NowPlayingTrack: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String?
    var albumArtist: String?
    var durationMs: Int?
    var positionMs: Int
    var state: PlaybackState
    /// Empreinte stable de la pochette : le serveur ne la redemande qu'une fois.
    var artworkHash: String?
    var trackId: String?
    /// Identifiant du morceau dans le catalogue Apple Music, quand il en a un.
    /// Permet de retrouver la pochette exacte, sans recherche approximative.
    var storeId: String?
    var capturedAt: Date

    /// Deux instantanés décrivent-ils le même morceau ?
    func isSameSong(as other: NowPlayingTrack) -> Bool {
        trackId == other.trackId && title == other.title && artist == other.artist
    }

    /// Un changement digne d'être signalé au serveur immédiatement.
    func differsMeaningfully(from other: NowPlayingTrack, positionTolerance: TimeInterval) -> Bool {
        if !isSameSong(as: other) { return true }
        if state != other.state { return true }

        // Position attendue si la lecture s'était poursuivie sans intervention.
        let elapsed = capturedAt.timeIntervalSince(other.capturedAt)
        let expected = other.state == .playing
            ? Double(other.positionMs) + elapsed * 1000
            : Double(other.positionMs)

        return abs(Double(positionMs) - expected) > positionTolerance * 1000
    }
}

extension NowPlayingTrack {
    /// Construit un instantané à partir de l'élément joué par l'app Musique.
    init?(item: MPMediaItem, state: PlaybackState, position: TimeInterval) {
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = (item.artist ?? item.albumArtist)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Sans titre ni artiste, il n'y a rien d'utile à afficher sur Discord.
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        self.title = title
        self.artist = artist
        self.album = item.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.albumArtist = item.albumArtist
        self.durationMs = item.playbackDuration > 0 ? Int(item.playbackDuration * 1000) : nil
        self.positionMs = max(0, Int(position * 1000))
        self.state = state
        self.trackId = String(item.persistentID)
        // « 0 » signale un morceau absent du catalogue (fichier importé).
        let store = item.playbackStoreID
        self.storeId = (store.isEmpty || store == "0") ? nil : store
        self.capturedAt = Date()
        self.artworkHash = Self.artworkHash(for: item)
    }

    /// Empreinte de l'album : stable d'un morceau à l'autre du même disque,
    /// ce qui évite de renvoyer la même pochette à chaque piste.
    private static func artworkHash(for item: MPMediaItem) -> String? {
        guard item.artwork != nil else { return nil }

        let seed: String
        if let album = item.albumTitle, !album.isEmpty {
            seed = "\(item.albumPersistentID)|\(album)|\(item.albumArtist ?? item.artist ?? "")"
        } else {
            seed = "track|\(item.persistentID)"
        }

        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).lowercased()
    }
}
