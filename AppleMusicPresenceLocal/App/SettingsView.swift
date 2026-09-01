import SwiftUI

struct SettingsView: View {
    @Environment(PresenceCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var settings = AppSettings.shared

    @State private var discordToken = ""
    @State private var applicationId = ""
    @State private var activityName = ""
    @State private var lastfmKey = ""
    @State private var lastfmSecret = ""
    @State private var isLinking = false

    private let statuses = [
        ("online", "En ligne"),
        ("idle", "Absent"),
        ("dnd", "Ne pas déranger"),
        ("invisible", "Invisible")
    ]

    var body: some View {
        NavigationStack {
            Form {
                discordSection
                appearanceSection
                lastfmSection
                aboutSection
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }
                }
            }
            .onAppear {
                discordToken = settings.discordToken
                applicationId = settings.applicationId
                activityName = settings.activityName
                lastfmKey = settings.lastfmApiKey
                lastfmSecret = settings.lastfmApiSecret
            }
        }
    }

    private var discordSection: some View {
        Section {
            SecureField("Token de compte", text: $discordToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("Identifiant d'application", text: $applicationId)
                .keyboardType(.numberPad)
        } header: {
            Text("Discord")
        } footer: {
            Text("""
                Le token reste dans le trousseau de l'iPhone et n'est envoyé qu'à Discord.

                Discord interdit les clients tiers dans ses conditions d'utilisation : \
                utiliser un token de compte expose celui-ci à une suspension. \
                Changer ton mot de passe Discord invalide le token.
                """)
        }
    }

    private var appearanceSection: some View {
        Section {
            TextField("Apple Music", text: $activityName)

            Picker("Statut", selection: Binding(
                get: { settings.status },
                set: { settings.status = $0 }
            )) {
                ForEach(statuses, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }

            Toggle("Afficher en pause", isOn: $settings.showWhenPaused)
        } header: {
            Text("Apparence")
        } footer: {
            Text("Le nom s'affiche après « Écoute… ». Discord peut lui préférer le nom de l'application.")
        }
    }

    private var lastfmSection: some View {
        Section {
            Toggle("Scrobbling", isOn: $settings.lastfmEnabled)

            if settings.lastfmEnabled {
                SecureField("Clé d'API", text: $lastfmKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Secret partagé", text: $lastfmSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if settings.isLastfmLinked {
                    LabeledContent("Compte lié", value: settings.lastfmUsername)
                    Button("Délier", role: .destructive) { coordinator.unlinkLastfm() }
                } else {
                    Button {
                        Task { await link() }
                    } label: {
                        HStack {
                            Text(settings.pendingLastfmToken.isEmpty
                                 ? "Autoriser sur Last.fm"
                                 : "Réessayer l'autorisation")
                            Spacer()
                            if isLinking { ProgressView() }
                        }
                    }
                    .disabled(isLinking || lastfmKey.isEmpty || lastfmSecret.isEmpty)

                    if !settings.pendingLastfmToken.isEmpty {
                        Button("J'ai autorisé, terminer") {
                            Task { await coordinator.finishLastfmLink() }
                        }
                    }
                }
            }
        } header: {
            Text("Last.fm")
        } footer: {
            Text("""
                Crée une clé sur last.fm/api/account/create. Aucune URL de retour n'est \
                nécessaire : après avoir autorisé dans Safari, reviens dans l'app, \
                la liaison se termine toute seule.
                """)
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.shortVersion)
        } footer: {
            Text("""
                L'app maintient une session audio silencieuse pour rester active écran \
                éteint. Elle n'interrompt jamais la musique.
                """)
        }
    }

    // MARK: - Actions

    private func save() {
        settings.discordToken = discordToken.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.applicationId = applicationId.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.activityName = activityName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.lastfmApiKey = lastfmKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.lastfmApiSecret = lastfmSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        // Une nouvelle configuration doit repartir sur une connexion propre.
        coordinator.reload()
        dismiss()
    }

    private func link() async {
        isLinking = true
        defer { isLinking = false }

        // Les clés doivent être enregistrées avant la demande de jeton.
        settings.lastfmApiKey = lastfmKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.lastfmApiSecret = lastfmSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = await coordinator.beginLastfmLink() {
            openURL(url)
        }
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
