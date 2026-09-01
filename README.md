# Apple Music → Discord Rich Presence (iOS)

Affiche sur ton profil Discord ce que joue **l'application Musique de ton iPhone**,
en continu, y compris écran éteint. Scrobble aussi sur Last.fm, si tu veux.

**Aucun serveur.** L'app tient elle-même la connexion à Discord, résout les
pochettes et envoie les scrobbles. Pas de VPS, pas de domaine, pas de Docker.

```
┌──────────────────────────────┐        ┌─────────┐
│           iPhone             │───────▶│ Discord │
│  app Musique → cette app     │        └─────────┘
│  Gateway · iTunes · Last.fm  │───────▶┌─────────┐
└──────────────────────────────┘        │ Last.fm │
                                        └─────────┘
```

---

## ⚠️ À lire avant toute chose

Cette application se connecte à Discord avec **le token de ton compte**, en se
présentant comme un client Discord. **Les conditions d'utilisation de Discord
interdisent les clients tiers : ton compte s'expose à une suspension.**

Ce n'est pas un choix de confort. Sur iOS, aucune application ne peut parler au
client Discord — il n'y a pas d'IPC local comme sur macOS ou Windows. La seule voie
officielle serait le scope OAuth2 `activities.write`, que Discord réserve à des
partenaires commerciaux : une application personnelle reçoit `invalid_scope` au
moment d'autoriser, même lorsque l'écran de consentement affiche « Mets à jour ton
activité en cours ».

Si ce risque ne te convient pas, il n'existe aucune alternative fonctionnelle, et
c'est une raison parfaitement valable de ne pas utiliser ce projet. Le scrobbling
Last.fm, lui, n'a aucune de ces contraintes et peut s'utiliser seul.

---

## Ce que ça fait

- **Suit uniquement l'app Musique.** Le lecteur système est observé directement :
  Spotify, YouTube ou Deezer gèrent leur propre session audio et n'y apparaissent
  jamais. La restriction est structurelle, pas filtrée après coup.
- **Tourne en arrière-plan sans interruption**, écran verrouillé.
- **Affiche la pochette exacte**, retrouvée par identifiant de catalogue Apple.
- **Barre de progression** synchronisée sur la lecture réelle.
- **Scrobble sur Last.fm** selon les règles officielles, avec une file d'attente
  qui survit aux coupures réseau.
- **Le token reste dans le trousseau de l'iPhone.** Il n'est envoyé qu'à Discord.

## Prérequis

- Un iPhone sous **iOS 17** ou plus
- **Xcode 16** ou plus, avec un compte Apple (un compte gratuit suffit)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Installation

```bash
git clone <ce-dépôt>
cd ios-no_server
xcodegen generate
open AppleMusicPresenceLocal.xcodeproj
```

Dans Xcode : sélectionne la cible **AppleMusicPresenceLocal**, onglet
**Signing & Capabilities**, choisis ton équipe de développement, puis lance sur ton
iPhone.

Au premier lancement, iOS refusera d'ouvrir l'app : va dans **Réglages → Général →
VPN et gestion de l'appareil**, et fais confiance à ton certificat de développeur.

> Un compte développeur gratuit signe l'app pour **7 jours**, après quoi il faut la
> réinstaller. Un compte payant porte cette durée à un an.

## Configuration

### Discord

1. Crée une application sur <https://discord.com/developers/applications>.
   Son **nom** est ce qui s'affiche après « Écoute… ». **Aucun bot à créer** : sur
   le portail, une « application » est une simple identité, distincte d'un bot.
2. Note son **Application ID** (page *General Information*).
3. Récupère ton token de compte : ouvre Discord **dans un navigateur**, `F12` →
   onglet **Réseau** → recharge la page → clique n'importe quelle requête vers
   `discord.com/api/` → lis l'en-tête **`Authorization`**.
4. Dans les réglages de l'app : colle le token et l'Application ID.

> Ce token vaut un accès complet à ton compte : traite-le comme un mot de passe.
> Il ne quitte pas le trousseau de l'iPhone. Changer ton mot de passe Discord
> l'invalide — c'est le moyen de le révoquer s'il fuit.

Dépose éventuellement une image dans *Rich Presence → Art Assets* du portail : elle
servira d'icône par défaut.

### Last.fm (facultatif)

1. Crée une clé d'API sur <https://www.last.fm/api/account/create>.
   **Aucune URL de retour n'est nécessaire.**
2. Dans les réglages de l'app : active le scrobbling, colle la clé et le secret.
3. Touche **Autoriser sur Last.fm** — Safari s'ouvre, tu autorises, tu reviens dans
   l'app. La liaison se termine toute seule.

## Comment ça marche

### Ne suivre que l'app Musique

L'app lit `MPMusicPlayerController.systemMusicPlayer`, le lecteur système, dont la
file de lecture *est* celle de l'app Musique. Les lecteurs tiers gèrent leur propre
session audio et n'y figurent jamais.

### Rester actif en arrière-plan

iOS suspend une application quelques secondes après son passage en arrière-plan,
sauf si elle déclare un mode d'arrière-plan. Le seul qui permette une surveillance
continue est `audio` : l'app entretient une session audio en jouant une boucle
inaudible (−90 dBFS), configurée en `.mixWithOthers` pour **ne jamais interrompre ta
musique** ni apparaître sur l'écran verrouillé. Un chien de garde la reconstruit
après une interruption ou une réinitialisation des services média.

### La connexion Discord

[`DiscordGateway.swift`](AppleMusicPresenceLocal/Core/DiscordGateway.swift) tient une
session WebSocket : identification, battements de cœur, et `RESUME` plutôt qu'une
nouvelle identification à chaque reprise — Discord limite sévèrement les `IDENTIFY`.
Un battement resté sans accusé fait fermer la connexion pour déclencher une reprise,
plutôt que de la laisser morte en silence.

Deux réglages d'`URLSessionWebSocketTask` méritent l'attention — les deux ont coûté
des heures de reconnexions inexpliquées :

| Réglage | Valeur retenue | Pourquoi |
|---|---|---|
| `maximumMessageSize` | 32 Mo | **Le défaut est 1 Mo**, alors que le `READY` d'un compte utilisateur — serveurs, relations, réglages — en pèse plusieurs. La socket meurt sur « Message too long » à chaque tentative, en boucle infinie |
| `timeoutIntervalForRequest` | 300 s | Une session Gateway reste volontairement silencieuse entre deux battements (~41 s). Le défaut de 60 s passe de justesse, mais toute valeur plus courte coupe la connexion à chaque cycle |

### Les pochettes

[`ArtworkResolver.swift`](AppleMusicPresenceLocal/Core/ArtworkResolver.swift) passe
par l'identifiant du morceau dans le catalogue Apple Music (`playbackStoreID`), ce
qui donne la pochette exacte sans recherche approximative. Pour la musique importée,
qui n'a pas d'identifiant, il cherche sur iTunes puis **note les candidats** sur le
titre, l'artiste et l'album : le premier résultat d'une recherche est souvent un
remix ou une reprise. En dessous du seuil, aucune image n'est envoyée — une pochette
étrangère est pire que pas de pochette.

L'URL obtenue passe ensuite par le proxy média de Discord (`external-assets`). Cette
étape est indispensable : le client Discord de bureau la fait pour les applications
qui lui parlent en IPC, mais une activité envoyée par le Gateway doit arriver avec
une référence `mp:external/…` déjà résolue. Une URL `https://` brute s'affiche comme
un asset inconnu.

### Le scrobbling

[`LastfmScrobbler.swift`](AppleMusicPresenceLocal/Core/LastfmScrobbler.swift)
applique les règles de Last.fm : un morceau compte après **la moitié de sa durée ou
4 minutes**, selon ce qui arrive en premier, et jamais en dessous de 30 secondes.

Le temps est compté en lecture seulement — une pause ne compte pas — et un trou de
plus de 90 secondes dans le suivi n'est pas crédité : mieux vaut sous-estimer une
écoute que gonfler un scrobble. Relancer un morceau depuis le début après en avoir
écouté la moitié compte comme une nouvelle écoute.

Les écoutes en attente sont écrites sur disque et repartent par lots de 50 : une
coupure réseau ou une fermeture de l'app ne les perd pas.

Le client Last.fm est écrit à la main
([`LastfmClient.swift`](AppleMusicPresenceLocal/Core/LastfmClient.swift)). Le point
délicat est la signature : MD5 des paramètres triés par nom, concaténés `nomvaleur`,
suivis du secret partagé — `format` et `api_sig` **exclus** du calcul, ce qui est la
cause la plus fréquente d'un `Invalid method signature`.

## Limites connues

- **L'app doit tourner.** Elle survit au verrouillage, au changement d'app et à une
  longue session écran éteint, mais pas à une fermeture manuelle depuis le sélecteur
  d'apps ni à un redémarrage de l'iPhone. C'est une contrainte d'iOS.
- **Pas publiable sur l'App Store.** Le mode `audio` est ici employé sans lecture
  réelle ; l'app est faite pour un usage personnel, en signature de développement.
- **Les morceaux absents du catalogue Apple** (fichiers importés exotiques) peuvent
  rester sans pochette. Le journal de l'app indique pourquoi.

## Développement

```bash
xcodegen generate    # régénère le projet Xcode depuis project.yml
swiftlint            # règles dans .swiftlint.yml
./icon/build-icon.sh # régénère l'icône depuis icon/AppIcon.svg
```

> Sans installation complète d'Xcode, SwiftLint ne trouve pas `sourcekitd` et
> s'interrompt au démarrage. Le lancer alors avec
> `DYLD_FRAMEWORK_PATH=/Library/Developer/CommandLineTools/usr/lib`.

L'icône est vectorielle ([`icon/AppIcon.svg`](icon/AppIcon.svg)) : elle se retouche
et se réexporte sans perte. Le script l'aplatit sur un fond opaque, iOS refusant
toute transparence dans une icône d'application. Il demande `librsvg` et Pillow
(`brew install librsvg && pip3 install pillow`).

Le client Gateway et la signature Last.fm se testent **hors appareil** : ils ne
dépendent que de Foundation. Compile-les avec un `main.swift` d'essai et pointe
`DiscordGateway.endpointOverride` sur un faux Gateway local.

> Un mock de Gateway utile doit envoyer un `READY` de **plusieurs mégaoctets** et
> annoncer un `heartbeat_interval` réaliste (45 000 ms). Un mock trop léger valide
> du code qui ne tient pas trente secondes sur un vrai compte.

## Licence

[MIT](LICENSE)

L'icône reprend un glyphe de [Phosphor Icons](https://phosphoricons.com), également
sous licence MIT — voir [`icon/NOTICE.md`](icon/NOTICE.md).
