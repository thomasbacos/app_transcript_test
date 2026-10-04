# Architecture

Ce document est destiné à la personne (ou à l'assistant IA) qui reprendra le code. Il décrit les choix
qui ne se voient pas en lisant les fichiers un par un.

## Vue d'ensemble

```
App iPhone                                        Serveur
──────────                                        ───────
AudioRecorder ── CAF PCM 24 kHz ─▶ AAC .m4a
                                   │
ProcessingService ── POST /v1/jobs (options + documents) ─▶ job « awaiting_audio »
UploadManager ───── PUT /v1/jobs/{id}/audio (URLSession background) ─▶ « queued » ─▶ Runner (threads)
                                                                          │  pipeline/process.py
   ◀── push APNs « prêt » ── « done » ◀──────────────────────────────────┘
ProcessingService ── GET /v1/jobs/{id}/result ─▶ result.json (local)
                  ── DELETE /v1/jobs/{id}      ─▶ le serveur oublie tout
```

## Comptes, abonnements, quotas

- **Pas de compte utilisateur.** L'app envoie à `POST /v1/auth/session` les transactions signées que StoreKit 2
  détient (`Transaction.currentEntitlements`, format JWS). Le serveur les vérifie avec la bibliothèque officielle
  d'Apple (`app-store-server-library`) contre les certificats racine d'Apple (`server/certs/`).
  Le compte est alors `ot:<originalTransactionId>`. Un même identifiant Apple sur plusieurs appareils
  partage donc le même quota.
- Sans abonnement : le compte `inst:<install id>` (identifiant aléatoire conservé dans le trousseau) peut
  enregistrer en local, mais pas transcrire (`402 subscription_required`).
- **Essai** = l'offre de lancement App Store (gratuit, 1 semaine). Apple ne l'accorde qu'une fois par
  identifiant Apple, ce qui empêche les essais à répétition. Le serveur reconnaît la transaction d'essai
  (`offerType=1`, `offerDiscountType=FREE_TRIAL`) et applique `PLAN_TRIAL_MINUTES` au total de l'essai.
- **Formules payantes** : un quota mensuel. Les fenêtres sont ancrées sur la date d'achat de la transaction
  en cours ; un abonnement annuel est découpé en 12 fenêtres (`appstore.period_of`, `accounts.roll_period`).
- **Décompte** : à la création d'un job, sa durée déclarée est *réservée* (d'où le temps restant affiché
  tout de suite). La durée réelle, mesurée après l'envoi, est **facturée seulement en cas de succès**.
  Supprimer ses données ne rend pas de minutes : les compteurs d'usage sont anonymes et conservés.
- **Anti-abus** : 2 jobs actifs par compte, 30 jobs par jour, limite de session par IP, taille d'envoi
  plafonnée, durée maximale par fichier selon la formule.
- **Environnements acceptés** : `APPLE_ENVIRONMENTS`. `Production,Sandbox` couvre l'App Store, TestFlight
  et la vérification Apple. N'ajoutez `Xcode` (achats de `Products.storekit`, non signés par Apple) que sur
  un serveur de développement.
- **Notifications serveur App Store V2** (`/v1/appstore/notifications`) : renouvellements, remboursements
  (le compte passe à `revoked`), expirations.

## Pipeline de transcription (server/app/pipeline)

Il est porté de l'app Windows (`tools/transcribe`), avec les mêmes leçons durement apprises :

| Contrainte | Réponse |
|---|---|
| Upload OpenAI limité à 25 Mo | passe texte en AAC 16 kHz / 32 kbps ; au-delà de 24 Mo, découpe aux silences |
| Diarisation limitée à 1 400 s par requête | blocs de 5 min coupés au silence le plus proche, en parallèle (`DIARIZE_PARALLEL`) |
| Les étiquettes d'intervenants changent à chaque requête | le bloc 1 passe seul et fournit 2 à 8 s de voix par intervenant (max 4), qui ancrent les blocs suivants |
| Le modèle d'intervenants **traduit le français en anglais** à 16 kHz / ≤ 64 kbps | blocs d'intervenants ré-encodés en 24 kHz / 80 kbps |
| Il dérive vers l'anglais sans langue fournie | en détection auto, une sonde texte de 30 s donne la langue ; un bloc revenu en anglais est relancé une fois |
| Le paramètre `languages` est refusé (400) par la diarisation | `language=` à la place |
| Le modèle Sol n'est pas activé sur toutes les clés | bascule auto sur Astra, mémorisée 1 h (`llm.py`) |

Différences avec l'app Windows :
- la source est décodée **une seule fois** en WAV 16 kHz sur disque, avec une enveloppe de volume par
  fenêtres de 200 ms. La mémoire reste stable même pour 4 h d'audio ;
- la progression est rapportée par étape et par bloc d'intervenants ;
- le résumé renvoie aussi des **actions** (`task`, `owner`, `due`), affichées comme une liste à cocher ;
- les prompts sont neutres, sans référence au conseil ni à une entreprise.

**Reprise** : chaque morceau terminé (texte, sonde, chaque bloc d'intervenants, corrections, résumé) est mis
en cache dans le dossier du job. Une relance, automatique (3 tentatives pour les erreurs transitoires) ou
manuelle (`POST /retry`), ne refait que ce qui manque.

**Données** : l'audio et les documents sont supprimés dès la fin du job. Le résultat est supprimé dès que
l'app l'a récupéré, sinon au bout de `RESULT_RETENTION_HOURS` (72 h). Le cache est supprimé avec l'audio.

**Limite connue** : le runner tourne dans le processus de l'API et l'audio est sur le disque local, donc
**une seule instance**. C'est suffisant tant que l'essentiel du calcul se fait chez OpenAI. Pour plusieurs
instances, il faudrait un stockage objet (S3/R2) et une file partagée.

## App iOS

| Fichier | Rôle |
|---|---|
| `App/ParleyApp.swift`, `AppDelegate.swift` | point d'entrée ; push ; réveil par la session d'upload en arrière-plan |
| `App/AppModel.swift` | état global, navigation, démarrage d'un enregistrement, import, transcription automatique |
| `App/AppConfig.swift` | URL serveur et IDs produits (lus dans `Config/Parley.xcconfig` via Info.plist) |
| `Services/AudioRecorder.swift` | `AVAudioRecorder` en **CAF PCM 24 kHz** (récupérable après un crash), mode arrière-plan `audio`, pause et reprise automatiques pendant un appel, repères, Live Activity |
| `Services/AudioConverter.swift` | PCM → AAC (essaie 96 → 48 kbps), import de n'importe quel audio ou vidéo, `CAFRepair` qui reconstruit un WAV depuis un CAF jamais finalisé |
| `Services/APIClient.swift` | client HTTP (actor) : session à partir des JWS StoreKit, jobs, erreurs traduites |
| `Services/UploadManager.swift` | `URLSession` d'arrière-plan : l'envoi continue app fermée ou téléphone verrouillé |
| `Services/ProcessingService.swift` | machine à états d'un enregistrement : local → uploading → processing → done / failed, interrogation du serveur, reprise |
| `Services/SubscriptionManager.swift` | StoreKit 2 : produits, achat, restauration, éligibilité à l'essai |
| `Services/Exporter.swift` | PDF (HTML → `UIPrintPageRenderer`), texte, Markdown, SRT |
| `Services/RecordingStore.swift` | stockage par dossier `Application Support/Recordings/<id>/` (`meta.json`, audio, `result.json`, `docs/`) |
| `Support/Demo.swift` | mode captures d'écran (`-ParleyDemo -ParleyScreen …`), utilisé par la CI |
| `Shared/` | attributs de la Live Activity et `LiveActivityIntent` (pause, stop, repère), compilés dans l'app **et** l'extension |

**Localisation** : les clés sont le texte anglais. Les chaînes avec paramètres passent par `tr("… %@", x)`
pour garder des clés explicites. `scripts/build_strings.py` extrait les chaînes du code et régénère les
catalogues `.xcstrings` (EN + FR), avec les traductions françaises contenues dans le script.

**Projet Xcode** : il utilise des groupes synchronisés (Xcode 16+, `objectVersion 77`). Un fichier ajouté
dans `ios/Parley`, `ios/ParleyWidgets` ou `ios/Shared` est compilé sans toucher au projet.
`scripts/make_xcodeproj.py` régénère le projet si l'on doit ajouter une cible ou changer un réglage de build.

## CI (.github/workflows)

- `ios.yml` : compilation simulateur (Debug) et appareil (Release, sans signature) sur macOS 26 / Xcode 26.
  Les erreurs remontent en annotations.
- `server.yml` : `pytest` (faux OpenAI, audio de synthèse) et build Docker avec test de fumée.
- `screenshots.yml` : l'app en mode démo sur un simulateur 6,9" (FR + EN), poussée sur la branche `screenshots`.

## Idées pour la suite

- Transcription en direct pendant l'enregistrement (envoyer des tranches de 5 min au fil de l'eau).
- Synchronisation iCloud de l'historique entre appareils.
- Contrôle du Centre de contrôle et bouton Action (iOS 18 `ControlWidget` + `AudioRecordingIntent`).
- Packs d'heures supplémentaires (achats consommables) en plus des abonnements.
- Stockage objet et file partagée pour faire tourner plusieurs instances du serveur.
