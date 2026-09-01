import CryptoKit
import Foundation

/// Erreurs renvoyées par l'API Last.fm.
struct LastfmError: LocalizedError {
    let code: Int
    let message: String

    /// Réessayer plus tard a du sens.
    var isRetryable: Bool { [8, 11, 16, 29].contains(code) }
    /// La session est invalide : il faut relier le compte.
    var needsRelink: Bool { [4, 9, 14, 15].contains(code) }

    var errorDescription: String? { "Last.fm \(code) : \(message)" }
}

/// Clé et secret d'une application Last.fm.
struct LastfmAPIKeys: Sendable {
    var key: String
    var secret: String

    var isEmpty: Bool { key.isEmpty || secret.isEmpty }
}

/// Client de l'API Last.fm 2.0, écrit à la main.
actor LastfmClient {
    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    /// Signature `api_sig`.
    ///
    /// MD5 de tous les paramètres triés par nom, concaténés sans séparateur sous la
    /// forme `nomvaleur`, suivis du secret partagé. `format` et `api_sig` en sont
    /// exclus — les inclure est la cause la plus fréquente d'un « Invalid method
    /// signature ». Le tri est lexicographique sur le nom complet, ce qui vaut aussi
    /// pour la syntaxe indexée des lots (`artist[0]`, `artist[1]`, …).
    nonisolated static func signature(_ params: [String: String], secret: String) -> String {
        let payload = params
            .filter { $0.key != "format" && $0.key != "api_sig" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)\($0.value)" }
            .joined()

        let digest = Insecure.MD5.hash(data: Data((payload + secret).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Exécute un appel et renvoie la réponse JSON déjà validée.
    func call(
        method: String,
        params: [String: String],
        keys: LastfmAPIKeys,
        signed: Bool,
        usePost: Bool
    ) async throws -> [String: Any] {
        var merged = params.filter { !$0.value.isEmpty }
        merged["method"] = method
        merged["api_key"] = keys.key

        if signed {
            merged["api_sig"] = Self.signature(merged, secret: keys.secret)
        }
        // `format` arrive après la signature : Last.fm l'exclut du calcul.
        merged["format"] = "json"

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let query = merged.map { URLQueryItem(name: $0.key, value: $0.value) }

        var request: URLRequest
        if usePost {
            request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
            var body = URLComponents()
            body.queryItems = query
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        } else {
            components.queryItems = query
            request = URLRequest(url: components.url!)
        }

        let (data, response) = try await session.data(for: request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Last.fm renvoie parfois du HTML quand le service est en maintenance.
            throw LastfmError(code: 11, message: "réponse illisible")
        }

        if let code = json["error"] as? Int {
            throw LastfmError(code: code, message: json["message"] as? String ?? "erreur inconnue")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            throw LastfmError(code: status >= 500 ? 11 : 8, message: "HTTP \(status)")
        }

        return json
    }

    // MARK: - Authentification

    /// Étape 1 : obtenir un jeton de demande.
    func requestToken(keys: LastfmAPIKeys) async throws -> String {
        let json = try await call(
            method: "auth.getToken", params: [:], keys: keys, signed: true, usePost: false
        )
        guard let token = json["token"] as? String else {
            throw LastfmError(code: 8, message: "jeton absent de la réponse")
        }
        return token
    }

    /// Étape 2 : l'URL sur laquelle envoyer l'utilisateur.
    nonisolated static func authorizeURL(apiKey: String, token: String) -> URL {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token)
        ]
        return components.url!
    }

    /// Étape 3 : échanger le jeton autorisé contre une clé de session permanente.
    func createSession(
        token: String,
        keys: LastfmAPIKeys
    ) async throws -> (key: String, username: String) {
        let json = try await call(
            method: "auth.getSession", params: ["token": token], keys: keys, signed: true, usePost: false
        )
        guard let session = json["session"] as? [String: Any],
              let key = session["key"] as? String,
              let name = session["name"] as? String
        else {
            throw LastfmError(code: 8, message: "session absente de la réponse")
        }
        return (key, name)
    }
}
