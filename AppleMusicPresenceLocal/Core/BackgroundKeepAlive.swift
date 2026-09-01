import AVFoundation
import Foundation
import Observation

/// Maintient le processus vivant en arrière-plan.
///
/// iOS suspend une application quelques secondes après son passage en arrière-plan,
/// sauf si elle utilise un mode d'arrière-plan déclaré. Le seul mode adapté à une
/// surveillance continue de la lecture est `audio` : l'app entretient une session
/// audio active en jouant un signal inaudible.
///
/// La session est configurée en `.mixWithOthers` : elle ne prend jamais la main sur
/// l'audio en cours, ne coupe pas la musique et n'apparaît pas sur l'écran verrouillé.
/// La lecture depuis l'app Musique se poursuit exactement comme si l'app n'était pas là.
@MainActor
@Observable
final class BackgroundKeepAlive {
    private(set) var isRunning = false
    private(set) var lastIssue: String?

    private var player: AVAudioPlayer?
    private var watchdog: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !isRunning else { return }

        do {
            try activateSession()
            try startSilentLoop()
            registerObservers()
            startWatchdog()
            isRunning = true
            lastIssue = nil
        } catch {
            lastIssue = "Arrière-plan indisponible : \(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        player?.stop()
        player = nil

        // `notifyOthersOnDeactivation` évite de laisser les autres apps en sourdine.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

    // MARK: - Session audio

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .default,
            // Sans `.mixWithOthers`, activer la session mettrait en pause l'app Musique.
            options: [.mixWithOthers]
        )
        try session.setActive(true)
    }

    private func startSilentLoop() throws {
        let player = try AVAudioPlayer(data: Self.silentWAV())
        // Boucle infinie : la session audio ne doit jamais retomber inactive.
        player.numberOfLoops = -1
        // Assez bas pour être inaudible, assez haut pour rester un vrai flux audio.
        player.volume = 0.005
        player.prepareToPlay()
        player.play()
        self.player = player
    }

    // MARK: - Robustesse

    private func registerObservers() {
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated { self?.handleInterruption(notification) }
            }
        )

        // Un redémarrage des services média invalide session et lecteur.
        observers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild(reason: "services média réinitialisés") }
            }
        )
    }

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            // L'appel entrant (ou autre) a suspendu notre boucle : on la reprendra à la fin.
            lastIssue = "Session audio interrompue"
        case .ended:
            rebuild(reason: "fin d'interruption")
        @unknown default:
            break
        }
    }

    /// Reconstruit session et lecteur après un incident.
    private func rebuild(reason: String) {
        player?.stop()
        player = nil
        do {
            try activateSession()
            try startSilentLoop()
            lastIssue = nil
        } catch {
            lastIssue = "Reprise impossible (\(reason)) : \(error.localizedDescription)"
        }
    }

    /// Filet de sécurité : vérifie régulièrement que la boucle tourne toujours.
    private func startWatchdog() {
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                if self.player?.isPlaying != true {
                    self.rebuild(reason: "boucle silencieuse arrêtée")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    // MARK: - Signal

    /// Construit en mémoire un WAV PCM d'une seconde, à la limite du silence.
    ///
    /// Un silence numérique absolu peut être écarté par la chaîne audio ; un signal
    /// à 1 LSB (environ −90 dBFS, donc inaudible) garantit un flux réel.
    private static func silentWAV(seconds: Int = 1, sampleRate: Int = 44_100) -> Data {
        let frameCount = seconds * sampleRate
        let dataSize = frameCount * 2 // 16 bits, mono
        var data = Data(capacity: 44 + dataSize)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                      // taille du bloc fmt
        append(UInt16(1))                       // PCM
        append(UInt16(1))                       // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))          // octets par seconde
        append(UInt16(2))                       // alignement de bloc
        append(UInt16(16))                      // bits par échantillon

        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))

        for index in 0..<frameCount {
            append(Int16(index % 2 == 0 ? 1 : -1))
        }

        return data
    }
}
