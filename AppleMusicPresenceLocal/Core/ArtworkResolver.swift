import Foundation

/// Trouve l'image à afficher dans la présence.
///
/// Deux étapes : retrouver une URL publique de pochette dans le catalogue Apple,
/// puis la faire passer par le proxy média de Discord. Cette seconde étape est
/// indispensable ici : le client Discord de bureau la fait pour les applications
/// qui lui parlent en IPC, mais une activité envoyée par le Gateway doit arriver
/// avec une référence `mp:external/…` déjà résolue — une URL `https://` brute
/// s'affiche comme un asset inconnu.
actor ArtworkResolver {
    private let session: URLSession

    /// Résultats déjà résolus, conservés d'un lancement à l'autre.
    ///
    /// Seules les références `mp:` y entrent : mémoriser une URL brute reviendrait
    /// à figer un échec, puisqu'elle ne s'affichera jamais.
    private var resolved: [String: String]
    private let resolvedKey = "artworkResolvedCache"
    private let resolvedLimit = 400

    /// Catalogue interrogé et côté de l'image demandée.
    var country = "FR"
    var size = 512

    /// Journalisation confiée à l'appelant, pour rester visible dans l'app.
    var onLog: (@Sendable (ActivityLog.Level, String) -> Void)?

    init() {
        let configuration = URLSessionConfiguration.default
        // Court volontairement : une pochette qui tarde ne doit pas retarder la
        // présence, elle arrivera à la mise à jour suivante.
        configuration.timeoutIntervalForRequest = 6
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        resolved = UserDefaults.standard.dictionary(forKey: resolvedKey) as? [String: String] ?? [:]
    }

    func setLogger(_ logger: @escaping @Sendable (ActivityLog.Level, String) -> Void) {
        onLog = logger
    }

    // MARK: - Cache

    private nonisolated func cacheKey(for track: NowPlayingTrack) -> String {
        // L'identifiant de catalogue désigne un morceau sans ambiguïté ; à défaut,
        // on retombe sur les métadonnées.
        if let storeId = track.storeId { return "store:\(storeId)" }
        return [track.artist, track.album ?? "", track.title].joined(separator: "|").lowercased()
    }

    /// Image déjà connue pour ce morceau, sans aucun appel réseau.
    func cachedImage(for track: NowPlayingTrack) -> String? {
        resolved[cacheKey(for: track)]
    }

    private func remember(_ image: String, for track: NowPlayingTrack) {
        // Ne conserve que ce qui s'affichera réellement.
        guard image.hasPrefix("mp:") else { return }
        resolved[cacheKey(for: track)] = image

        // Purge grossière : au-delà de la limite, on repart à vide plutôt que de
        // tenir un ordre d'usage dont le coût dépasserait le bénéfice.
        if resolved.count > resolvedLimit { resolved.removeAll() }
        UserDefaults.standard.set(resolved, forKey: resolvedKey)
    }

    // MARK: - Résolution

    /// Renvoie la valeur à placer dans `assets.large_image`.
    func resolve(track: NowPlayingTrack, discordToken: String, applicationId: String) async -> String? {
        if let known = resolved[cacheKey(for: track)] { return known }
        guard let url = await artworkURL(for: track) else {
            onLog?(.warning, "Aucune pochette trouvée pour « \(track.title) ».")
            return nil
        }

        // Si le proxy refuse, l'URL brute est renvoyée sans être mémorisée : elle
        // ne s'affichera pas, mais le prochain essai pourra réussir.
        guard let asset = await toExternalAsset(url: url, token: discordToken, applicationId: applicationId)
        else { return url }

        remember(asset, for: track)
        return asset
    }

    /// URL de la pochette dans le catalogue Apple.
    private func artworkURL(for track: NowPlayingTrack) async -> String? {
        // Voie exacte : l'app Musique connaît l'identifiant du morceau joué.
        if let storeId = track.storeId, let url = await lookup(storeId: storeId) {
            return url
        }
        // Voie approchée, pour la musique importée : on cherche, puis on vérifie.
        return await searchBestMatch(for: track)
    }

    // MARK: - Recherche exacte

    /// Interroge le catalogue par identifiant : le résultat est le bon par construction.
    private func lookup(storeId: String) async -> String? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: storeId),
            URLQueryItem(name: "country", value: country)
        ]
        guard let url = components.url,
              let results = await fetchResults(from: url),
              let first = results.first
        else { return nil }

        return scaled(first.artworkUrl100)
    }

    // MARK: - Recherche approchée

    private struct Result: Decodable {
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let artworkUrl100: String?
    }

    /// Cherche puis **vérifie** : le premier résultat d'iTunes est souvent un
    /// remix, une reprise ou une version alternative. On note chaque candidat et
    /// on n'accepte que s'il correspond vraiment.
    private func searchBestMatch(for track: NowPlayingTrack) async -> String? {
        let attempts = [
            [track.title, track.artist, track.album].compactMap { $0 }.joined(separator: " "),
            "\(track.title) \(track.artist)"
        ]

        var best: (score: Int, url: String)?

        for term in attempts.uniqued() where !term.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let results = await search(term: term) else { continue }

            for result in results {
                let score = self.score(result, against: track)
                if score > (best?.score ?? 0), let artwork = scaled(result.artworkUrl100) {
                    best = (score, artwork)
                }
            }
            // Une correspondance parfaite ne sera pas améliorée par la requête suivante.
            if let best, best.score >= 100 { return best.url }
        }

        // En dessous du seuil, mieux vaut aucune image qu'une pochette étrangère.
        guard let best, best.score >= 60 else { return nil }
        return best.url
    }

    /// Note un candidat de 0 à 130 : titre et artiste pèsent le plus, l'album départage.
    private func score(_ result: Result, against track: NowPlayingTrack) -> Int {
        let title = Self.normalize(track.title)
        let artist = Self.normalize(track.artist)
        let candidateTitle = Self.normalize(result.trackName)
        let candidateArtist = Self.normalize(result.artistName)

        var total = 0

        if candidateTitle == title {
            total += 60
        } else if candidateTitle.hasPrefix(title) || title.hasPrefix(candidateTitle) {
            // « New Genesis » face à « New Genesis (UTA from ONE PIECE FILM RED) ».
            total += 35
        } else if candidateTitle.contains(title) {
            total += 20
        } else {
            return 0
        }

        if candidateArtist == artist {
            total += 40
        } else if candidateArtist.contains(artist) || artist.contains(candidateArtist) {
            total += 25
        }

        if let album = track.album, !album.isEmpty {
            let expected = Self.normalize(album)
            let candidateAlbum = Self.normalize(result.collectionName)
            if candidateAlbum == expected {
                total += 30
            } else if candidateAlbum.contains(expected) || expected.contains(candidateAlbum) {
                total += 15
            }
        }

        return total
    }

    /// Minuscules, sans accents ni ponctuation : « Usseewa » et « Ussewa »
    /// restent distincts, mais « The World's » et « The Worlds » se rejoignent.
    private static func normalize(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func search(term: String) async -> [Result]? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            // Plusieurs candidats, puisqu'on les départage nous-mêmes.
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: country)
        ]
        guard let url = components.url else { return nil }
        return await fetchResults(from: url)
    }

    private func fetchResults(from url: URL) async -> [Result]? {
        struct Response: Decodable { let results: [Result] }

        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(Response.self, from: data).results
        } catch {
            return nil
        }
    }

    /// `artworkUrl100` pointe une vignette ; la même URL sert toutes les tailles.
    private func scaled(_ artworkUrl100: String?) -> String? {
        artworkUrl100?.replacingOccurrences(of: "100x100bb", with: "\(size)x\(size)bb")
    }

    // MARK: - Proxy média Discord

    private func toExternalAsset(url: String, token: String, applicationId: String) async -> String? {
        guard !token.isEmpty, !applicationId.isEmpty else { return nil }

        var request = URLRequest(
            url: URL(string: "https://discord.com/api/v10/applications/\(applicationId)/external-assets")!
        )
        request.httpMethod = "POST"
        // Un token de compte se présente nu, sans préfixe « Bearer ».
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["urls": [url]])

        struct Asset: Decodable {
            let path: String?

            enum CodingKeys: String, CodingKey {
                case path = "external_asset_path"
            }
        }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard status == 200 else {
                // Sans cette étape, Discord affichera un asset non résolu : il faut
                // que la cause soit visible dans le journal de l'app.
                onLog?(.warning, "Discord a refusé la pochette (HTTP \(status)).")
                return nil
            }

            return try JSONDecoder().decode([Asset].self, from: data).first?.path.map { "mp:\($0)" }
        } catch {
            onLog?(.warning, "Pochette : \(error.localizedDescription)")
            return nil
        }
    }
}

private extension Array where Element: Hashable {
    /// Conserve l'ordre en retirant les doublons.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
