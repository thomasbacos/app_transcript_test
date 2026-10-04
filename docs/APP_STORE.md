# Fiche App Store, textes prêts à coller

## Identité

| Champ | FR | EN |
|---|---|---|
| Nom (30 car.) | Parley | Parley |
| Sous-titre (30 car.) | Réunions transcrites et résumées | Meetings, transcribed & summed up |
| Catégorie | Productivité (secondaire : Économie et entreprise) | Productivity (Business) |
| Âge | 4+ | 4+ |
| Prix de l'app | Gratuite (abonnements intégrés) | Free (in-app subscriptions) |

**Mots-clés FR** (100 car. max, sans espace après les virgules) :
`transcription,réunion,compte rendu,dictaphone,résumé,enregistreur,notes,IA,verbatim,interview,cours`

**Keywords EN**:
`transcribe,meeting,notes,recorder,summary,minutes,AI,dictation,interview,lecture,speaker,voice memo`

**Texte promotionnel FR** (modifiable sans nouvelle version) :
> Essai gratuit de 7 jours. Posez votre iPhone, Parley s'occupe du compte rendu.

**Promotional text EN**:
> 7-day free trial. Put your iPhone down, Parley writes the minutes.

## Description FR

```
Parley enregistre vos réunions, cours et entretiens, puis vous donne la transcription complète, qui a dit quoi, et un résumé avec les actions à mener.

ENREGISTREZ SANS Y PENSER
• Continue d'enregistrer écran verrouillé, pendant des heures
• Se met en pause pendant un appel et reprend tout seul
• Minuteur et commandes sur l'écran verrouillé et dans la Dynamic Island
• Marquez les moments importants d'un geste
• Ou importez un fichier audio ou vidéo existant

QUI A DIT QUOI
• Chaque intervenant est identifié automatiquement
• Les prénoms sont reconnus quand les gens se présentent ; renommez-les d'un geste
• Touchez une phrase pour la réécouter

LE RÉSUMÉ, PRÊT À PARTAGER
• Points clés, thèmes, décisions et liste d'actions à cocher
• Correction intelligente des noms, acronymes et chiffres, aidée par vos documents (ordre du jour, présentation)
• Export PDF, texte, Markdown (Notion, Obsidian) ou sous-titres
• Français, anglais et plus de 20 langues, détectées automatiquement

CONFIDENTIALITÉ
• Transcription par OpenAI, uniquement après votre accord explicite
• Pas de compte à créer
• Vos enregistrements restent sur votre iPhone tant que vous ne les transcrivez pas
• L'audio est supprimé de nos serveurs dès la fin du traitement
• Aucune publicité, aucun traçage

ABONNEMENTS
Essai gratuit de 7 jours, puis Essentiel (4 h par mois) ou Pro (10 h par mois, mensuel ou annuel). Le paiement est débité sur votre identifiant Apple. L'abonnement se renouvelle automatiquement sauf résiliation au moins 24 h avant la fin de la période, depuis les réglages de votre compte.

Conditions : https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Confidentialité : https://<votre serveur>/legal/privacy

Pensez à prévenir les personnes que vous enregistrez.
```

## Description EN

```
Parley records your meetings, lectures and interviews, then gives you the full transcript, who said what, and a summary with the action items.

RECORD WITHOUT THINKING ABOUT IT
• Keeps recording with the screen locked, for hours
• Pauses during a phone call and resumes on its own
• Timer and controls on the Lock Screen and in the Dynamic Island
• Mark key moments with one tap
• Or import an existing audio or video file

WHO SAID WHAT
• Every speaker is identified automatically
• Names are picked up when people introduce themselves; rename anyone in one tap
• Tap a sentence to hear it again

THE SUMMARY, READY TO SHARE
• Key points, themes, decisions and a checklist of action items
• Smart correction of names, acronyms and figures, helped by your documents (agenda, slides)
• Export to PDF, text, Markdown (Notion, Obsidian) or subtitles
• English, French and 20+ languages, detected automatically

PRIVACY
• Transcription by OpenAI, only after your explicit consent
• No account to create
• Recordings stay on your iPhone until you choose to transcribe them
• Audio is deleted from our servers as soon as processing ends
• No ads, no tracking

SUBSCRIPTIONS
7-day free trial, then Essential (4 h per month) or Pro (10 h per month, monthly or yearly). Payment is charged to your Apple ID. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the period, in your account settings.

Terms: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy: https://<your server>/legal/privacy

Remember to tell people you are recording them.
```

## Captures d'écran (6,9", 1320 × 2868)

Simulateur *iPhone 17 Pro Max* → *File → Save Screen* (⌘S). Ordre conseillé, avec une légende courte :

1. **Enregistrement en cours** (écran sombre avec minuteur et onde) : « Enregistre même écran verrouillé »
2. **Résumé** avec la liste d'actions : « Le compte rendu, prêt en quelques minutes »
3. **Transcription** avec intervenants colorés : « Qui a dit quoi »
4. **Écran verrouillé avec la Live Activity** (sur un vrai iPhone) : « Pause, repère, stop depuis l'écran verrouillé »
5. **Accueil** avec plusieurs enregistrements : « Tout retrouver, tout chercher »

Pour des captures réalistes, enregistrez une vraie réunion de test, ou importez un podcast.

## Confidentialité de l'app (App Store Connect → Confidentialité de l'app)

« Collectez-vous des données ? » → **Oui**. Pour chacune : **non liée à l'identité**, **pas de traçage**,
finalité **Fonctionnalité de l'app** uniquement.

| Catégorie Apple | Type | Pourquoi |
|---|---|---|
| Contenu utilisateur | Données audio | Enregistrements envoyés pour transcription (supprimés après traitement) |
| Contenu utilisateur | Autre contenu utilisateur | Documents de référence, transcriptions (supprimés après téléchargement) |
| Achats | Historique d'achats | Vérification de l'abonnement auprès d'Apple |
| Identifiants | Identifiant de l'appareil | Identifiant aléatoire d'installation, jeton de notification |

Ces déclarations correspondent au manifeste `ios/Parley/Resources/PrivacyInfo.xcprivacy`.

## Notes pour l'équipe de vérification (App Review Information → Notes)

```
Parley records meetings and transcribes them on our server (OpenAI speech-to-text), then shows a transcript with speakers and an AI summary.

- No account / login: access is tied to the App Store subscription.
- To test transcription: on the paywall, start the 7-day free trial with your sandbox account (any plan), record 20-30 seconds of speech or import an audio file, then tap "Transcribe". The result appears within about a minute; a notification is sent when ready.
- Background audio (UIBackgroundModes: audio) is used only to keep recording a meeting while the screen is locked or another app is open, which is the core feature. A Live Activity shows the timer with pause / stop buttons.
- Recording without a subscription is possible (it stays on the device); transcription requires the trial or a subscription.
- Third-party AI (guideline 5.1.2(i)): before the first transcription, the app explains that the audio and any reference documents are sent to OpenAI and asks for explicit consent ("Agree and continue"). Nothing is sent before that.
- Privacy policy: https://<your server>/legal/privacy  — Terms: Apple standard EULA.
```

**Coordonnées** : votre nom, votre téléphone et votre e-mail. **Compte de démo** : non requis (cochez
« Connexion non requise »).

## Rappels avant de soumettre

- [ ] Contrat *Paid Apps* actif, banque et fiscalité renseignées
- [ ] 3 abonnements « Prêt à soumettre », avec capture de vérification et offre d'essai de 1 semaine
- [ ] `APPLE_APP_ID` renseigné sur le serveur, `APPLE_ENVIRONMENTS=Production,Sandbox` (sans `Xcode`)
- [ ] URL de confidentialité et d'assistance accessibles
- [ ] `PARLEY_API_BASE_URL` pointe vers le serveur de production (en HTTPS)
- [ ] Build testé sur TestFlight : enregistrement verrouillé, appel entrant, achat sandbox, transcription, export
