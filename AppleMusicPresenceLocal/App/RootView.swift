import MediaPlayer
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(PresenceCoordinator.self) private var coordinator
    @State private var settings = AppSettings.shared
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                nowPlayingSection
                if coordinator.watcher.authorizationStatus != .authorized {
                    authorizationSection
                }
                if settings.lastfmEnabled { lastfmSection }
                journalSection
            }
            .navigationTitle("Rich Presence")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Label("Réglages", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView().environment(coordinator)
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { coordinator.isActive },
                set: { coordinator.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Publier ma présence")
                    Text(coordinator.isActive ? "Suivi de l'app Musique en cours" : "En pause")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.isConfigured)

            LabeledContent("Discord") {
                Label(connectionLabel, systemImage: connectionIcon)
                    .foregroundStyle(connectionColor)
                    .labelStyle(.titleAndIcon)
            }

            LabeledContent("Arrière-plan") {
                Label(
                    coordinator.keepAlive.isRunning ? "Maintenu" : "Inactif",
                    systemImage: coordinator.keepAlive.isRunning ? "checkmark.circle.fill" : "moon.zzz"
                )
                .foregroundStyle(coordinator.keepAlive.isRunning ? .green : .secondary)
                .labelStyle(.titleAndIcon)
            }

            if let error = coordinator.gateway.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if !settings.isConfigured {
                Button("Configurer Discord") { showingSettings = true }
            }
        } header: {
            Text("État")
        } footer: {
            Text("Aucun serveur : l'app parle directement à Discord. Seule l'application Musique est suivie.")
        }
    }

    @ViewBuilder
    private var nowPlayingSection: some View {
        Section("En cours de lecture") {
            if let track = coordinator.watcher.current {
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title).font(.headline).lineLimit(2)
                    Text(track.artist).font(.subheadline).foregroundStyle(.secondary)
                    if let album = track.album, !album.isEmpty {
                        Text(album).font(.caption).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: track.state == .playing ? "play.fill" : "pause.fill")
                        Text(Self.timecode(track))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            } else {
                Text("L'app Musique ne joue rien.").foregroundStyle(.secondary)
            }
        }
    }

    private var authorizationSection: some View {
        Section("Autorisation") {
            Label(
                "L'accès à la médiathèque est nécessaire pour lire les informations du morceau.",
                systemImage: "music.note.list"
            )
            .font(.footnote)

            Button("Autoriser l'accès") {
                Task { await coordinator.watcher.requestAuthorization() }
            }
            if coordinator.watcher.authorizationStatus == .denied {
                Link("Ouvrir les Réglages", destination: URL(string: UIApplication.openSettingsURLString)!)
            }
        }
    }

    private var lastfmSection: some View {
        Section("Last.fm") {
            if settings.isLastfmLinked {
                LabeledContent("Compte", value: settings.lastfmUsername)
                LabeledContent("Envoyés", value: "\(coordinator.scrobbler.scrobbledThisSession)")
                if !coordinator.scrobbler.queue.isEmpty {
                    LabeledContent("En attente", value: "\(coordinator.scrobbler.queue.count)")
                        .foregroundStyle(.orange)
                }
                if coordinator.watcher.current != nil {
                    LabeledContent("Écoute comptée") {
                        let seconds = coordinator.scrobbler.listeningSeconds
                        let mark = coordinator.scrobbler.currentQualifies ? "✅" : "⏳"
                        Text("\(seconds) s \(mark)").monospacedDigit()
                    }
                }
            } else {
                Label("Compte non lié", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Lier dans les réglages") { showingSettings = true }
            }
        }
    }

    private var journalSection: some View {
        Section {
            if coordinator.log.entries.isEmpty {
                Text("Rien à signaler.").foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.log.entries.prefix(25)) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.level.symbol)
                            .foregroundStyle(color(for: entry.level))
                            .font(.caption)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message).font(.caption)
                            Text(entry.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        } header: {
            HStack {
                Text("Journal")
                Spacer()
                if !coordinator.log.entries.isEmpty {
                    Button("Effacer") { coordinator.log.clear() }
                        .font(.caption)
                        .textCase(nil)
                }
            }
        }
    }

    // MARK: - Présentation

    private var connectionLabel: String {
        switch coordinator.gateway.state {
        case .idle: return "Hors ligne"
        case .connecting: return "Connexion…"
        case .connected(let username): return username ?? "Connecté"
        case .reconnecting(let attempt): return "Reprise (\(attempt))"
        case .failed: return "Échec"
        }
    }

    private var connectionIcon: String {
        switch coordinator.gateway.state {
        case .connected: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .idle: return "moon.zzz"
        }
    }

    private var connectionColor: Color {
        switch coordinator.gateway.state {
        case .connected: return .green
        case .failed: return .red
        case .connecting, .reconnecting: return .orange
        case .idle: return .secondary
        }
    }

    private func color(for level: ActivityLog.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private static func timecode(_ track: NowPlayingTrack) -> String {
        func format(_ ms: Int) -> String {
            let total = ms / 1000
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        guard let duration = track.durationMs else { return format(track.positionMs) }
        return "\(format(track.positionMs)) / \(format(duration))"
    }
}
