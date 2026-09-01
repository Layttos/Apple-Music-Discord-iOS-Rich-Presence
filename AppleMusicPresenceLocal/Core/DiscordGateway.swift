import Foundation
import Observation

/// Client Gateway Discord, embarqué dans l'application.
///
/// Reprend le rôle que tenait le serveur relais : ouvrir une session avec le token
/// du compte, entretenir les battements de cœur, et pousser l'activité. Le token ne
/// quitte jamais l'appareil — il vit dans le trousseau.
///
/// ⚠️ Discord interdit les clients tiers dans ses conditions d'utilisation. Ce mode
/// n'existe que parce que le scope OAuth2 `activities.write` est réservé aux
/// applications approuvées ; le compte s'expose à une suspension.
@MainActor
@Observable
final class DiscordGateway {
    enum State: Equatable {
        case idle
        case connecting
        case connected(username: String?)
        case reconnecting(attempt: Int)
        /// Erreur définitive : inutile de réessayer sans intervention.
        case failed(reason: String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    private(set) var state: State = .idle
    private(set) var lastError: String?

    /// Journalisation confiée à l'appelant, pour rester affichable dans l'UI.
    var onLog: ((ActivityLog.Level, String) -> Void)?

    // MARK: - Opcodes

    private enum Opcode {
        static let dispatch = 0
        static let heartbeat = 1
        static let identify = 2
        static let presenceUpdate = 3
        static let resume = 6
        static let reconnect = 7
        static let invalidSession = 9
        static let hello = 10
        static let heartbeatAck = 11
    }

    /// Codes de fermeture après lesquels réessayer ne sert à rien.
    private static let fatalCloseCodes: [Int: String] = [
        4004: "token refusé — il est invalide ou a été révoqué",
        4010: "shard invalide",
        4011: "sharding requis",
        4012: "version de Gateway invalide",
        4013: "intents invalides",
        4014: "intents non autorisés"
    ]

    private let defaultGatewayURL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!

    /// Point d'entrée de rechange, utilisé par les tests contre un faux Gateway.
    var endpointOverride: URL?

    private var gatewayURL: URL { endpointOverride ?? defaultGatewayURL }

    private var token: String = ""
    private var applicationId: String = ""
    private var status: String = "online"

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession
    private var receiveLoop: Task<Void, Never>?
    private var heartbeatTimer: Timer?
    /// Premier battement, volontairement décalé.
    private var firstBeat: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var sequence: Int?
    private var sessionId: String?
    /// Discord fournit une URL dédiée pour reprendre une session.
    private var resumeURL: String?
    /// Un battement sans accusé signale une connexion morte.
    private var awaitingAck = false

    private var attempt = 0
    private var stopped = false
    /// Dernière activité demandée, rejouée à chaque reconnexion.
    private var desired: DiscordActivity?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        // Une socket Gateway reste volontairement silencieuse entre deux battements
        // (~41 s chez Discord). Un timeout de requête court la ferait tomber à
        // chaque cycle : il doit rester très au-dessus de cet intervalle.
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 604_800
        session = URLSession(configuration: configuration)
    }

    // MARK: - Cycle de vie

    func connect(token: String, applicationId: String, status: String) {
        self.token = token
        self.applicationId = applicationId
        self.status = status
        stopped = false
        attempt = 0
        openSocket(resuming: false)
    }

    func disconnect() async {
        stopped = true
        cancelReconnect()
        stopHeartbeat()

        if socket != nil {
            // Retire la présence avant de partir, sinon elle resterait figée.
            send(presenceFrame(nil))
            try? await Task.sleep(for: .milliseconds(250))
        }

        receiveLoop?.cancel()
        receiveLoop = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        sessionId = nil
        sequence = nil
        resumeURL = nil
        state = .idle
    }

    /// Pose l'activité, ou l'efface si `nil`.
    func setActivity(_ activity: DiscordActivity?) {
        desired = activity
        guard state.isConnected else { return }
        send(presenceFrame(activity))
    }

    // MARK: - Socket

    private func openSocket(resuming: Bool) {
        guard !stopped else { return }
        guard !token.isEmpty else {
            state = .failed(reason: "Aucun token Discord enregistré.")
            return
        }

        state = attempt == 0 ? .connecting : .reconnecting(attempt: attempt)

        // Reprendre une session coûte bien moins cher qu'une identification, que
        // Discord limite sévèrement.
        let canResume = resuming && sessionId != nil && sequence != nil
        let resumeEndpoint = resumeURL.flatMap { URL(string: "\($0)/?v=10&encoding=json") }
        let url = canResume ? (resumeEndpoint ?? gatewayURL) : gatewayURL

        let task = session.webSocketTask(with: url)
        // `URLSessionWebSocketTask` plafonne les messages entrants à 1 Mo. Le READY
        // d'un compte utilisateur — serveurs, relations, réglages — dépasse
        // largement cette limite, et la socket serait fermée sur « Message too
        // long » à chaque tentative.
        task.maximumMessageSize = 32 * 1024 * 1024
        socket = task
        task.resume()

        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            await self?.readMessages(resuming: canResume)
        }
    }

    private func readMessages(resuming: Bool) async {
        guard let task = socket else { return }
        pendingResume = resuming

        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handle(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handle(text: text) }
                @unknown default:
                    break
                }
            } catch {
                guard !stopped, !Task.isCancelled else { return }
                handleDisconnection(code: task.closeCode.rawValue, error: error)
                return
            }
        }
    }

    private var pendingResume = false
    private var handlingDisconnection = false

    private func handleDisconnection(code: Int, error: Error?) {
        // `closeForResume()` annule la socket, ce qui fait aussi échouer la lecture
        // en cours : sans ce garde, la même coupure serait traitée deux fois.
        guard !handlingDisconnection else { return }
        handlingDisconnection = true
        defer {
            Task { @MainActor in self.handlingDisconnection = false }
        }

        stopHeartbeat()
        if let error, code == 0 {
            onLog?(.info, "Socket interrompue : \(error.localizedDescription)")
        }

        if let reason = Self.fatalCloseCodes[code] {
            let message = "Connexion refusée (\(code)) : \(reason)"
            lastError = message
            state = .failed(reason: message)
            onLog?(.error, message)
            return
        }

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped, reconnectTask == nil else { return }
        attempt += 1

        // Repli exponentiel plafonné, avec gigue pour ne pas taper en cadence fixe.
        let base = min(30.0, pow(2.0, Double(min(attempt, 5))))
        let delay = base + Double.random(in: 0...1)
        state = .reconnecting(attempt: attempt)
        onLog?(.warning, "Reconnexion Discord dans \(Int(delay)) s (tentative \(attempt)).")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.openSocket(resuming: true)
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Protocole

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = frame["op"] as? Int
        else { return }

        if let seq = frame["s"] as? Int { sequence = seq }

        switch op {
        case Opcode.hello:
            handleHello(frame)
        case Opcode.dispatch:
            handleDispatch(frame)
        case Opcode.heartbeat:
            // Discord peut réclamer un battement hors cadence.
            awaitingAck = true
            send(["op": Opcode.heartbeat, "d": sequence as Any])
        case Opcode.heartbeatAck:
            awaitingAck = false
        case Opcode.reconnect:
            onLog?(.info, "Discord demande une reconnexion.")
            closeForResume()
        case Opcode.invalidSession:
            handleInvalidSession(frame)
        default:
            break
        }
    }

    private func handleHello(_ frame: [String: Any]) {
        let payload = frame["d"] as? [String: Any]
        let interval = (payload?["heartbeat_interval"] as? Double ?? 41250) / 1000
        startHeartbeat(interval: interval)

        if pendingResume, let sessionId, let sequence {
            send(["op": Opcode.resume, "d": ["token": token, "session_id": sessionId, "seq": sequence]])
        } else {
            sendIdentify()
        }
    }

    private func handleDispatch(_ frame: [String: Any]) {
        switch frame["t"] as? String {
        case "READY":
            let payload = frame["d"] as? [String: Any]
            sessionId = payload?["session_id"] as? String
            resumeURL = payload?["resume_gateway_url"] as? String
            let username = (payload?["user"] as? [String: Any])?["username"] as? String

            attempt = 0
            lastError = nil
            state = .connected(username: username)
            onLog?(.success, "Discord connecté en tant que \(username ?? "compte inconnu").")
            // L'activité passée à l'IDENTIFY n'est pas toujours retenue.
            send(presenceFrame(desired))

        case "RESUMED":
            attempt = 0
            lastError = nil
            state = .connected(username: nil)
            onLog?(.success, "Session Discord reprise.")
            send(presenceFrame(desired))

        default:
            break
        }
    }

    private func handleInvalidSession(_ frame: [String: Any]) {
        // `d == true` signale qu'une reprise reste possible.
        let resumable = frame["d"] as? Bool ?? false
        if !resumable {
            sessionId = nil
            sequence = nil
            resumeURL = nil
        }
        onLog?(.warning, "Session Discord invalide (reprise \(resumable ? "possible" : "impossible")).")
        closeForResume()
    }

    /// Ferme la socket de façon à déclencher une reprise plutôt qu'un arrêt.
    private func closeForResume() {
        pendingResume = true
        socket?.cancel(with: .goingAway, reason: nil)
        handleDisconnection(code: 4000, error: nil)
    }

    private func sendIdentify() {
        send([
            "op": Opcode.identify,
            "d": [
                "token": token,
                "capabilities": 161_789,
                "properties": [
                    "os": "iOS",
                    "browser": "Discord iOS",
                    "device": "iPhone",
                    "system_locale": "fr-FR",
                    "client_version": "239.0",
                    "os_version": "18.0",
                    "release_channel": "stable"
                ],
                "presence": presenceFrame(desired)["d"] as Any,
                "compress": false
            ]
        ])
    }

    private func presenceFrame(_ activity: DiscordActivity?) -> [String: Any] {
        var activities: [[String: Any]] = []

        if var activity {
            activity.applicationId = applicationId
            if let encoded = try? JSONEncoder().encode(activity),
               let dictionary = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
                activities = [dictionary]
            }
        }

        return [
            "op": Opcode.presenceUpdate,
            "d": ["since": 0, "activities": activities, "status": status, "afk": false]
        ]
    }

    private func send(_ payload: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else { return }

        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }

    // MARK: - Battements de cœur

    private func startHeartbeat(interval: TimeInterval) {
        stopHeartbeat()
        awaitingAck = false

        // Premier battement décalé au hasard, comme Discord le recommande.
        let jitter = interval * Double.random(in: 0...1)
        firstBeat = Task { [weak self] in
            try? await Task.sleep(for: .seconds(jitter))
            guard let self, !Task.isCancelled else { return }
            self.beat()
        }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                // Pas d'accusé depuis le dernier battement : la connexion est morte
                // en silence. On la ferme pour déclencher une reprise.
                self.beat()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    /// Envoie un battement, ou coupe la connexion si le précédent est resté sans accusé.
    private func beat() {
        if awaitingAck {
            onLog?(.warning, "Discord ne répond plus, reprise de la session.")
            closeForResume()
            return
        }
        awaitingAck = true
        send(["op": Opcode.heartbeat, "d": sequence as Any])
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        firstBeat?.cancel()
        firstBeat = nil
        awaitingAck = false
    }
}
