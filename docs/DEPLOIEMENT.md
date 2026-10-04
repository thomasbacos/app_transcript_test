# Mettre Parley en ligne, de zéro à l'App Store

Ce guide suit l'ordre réel des opérations. Compte environ **2 h de clics** la première fois, plus le délai
de validation d'Apple (24-48 h en général).

| Étape | Où | Durée |
|---|---|---|
| 0. Prérequis | — | — |
| 1. Déployer le serveur (il détient la clé OpenAI) | Render (ou tout hébergeur Docker) | 15 min |
| 2. Configurer et lancer l'app | Mac + Xcode | 15 min |
| 3. Créer l'app et les abonnements | App Store Connect | 45 min |
| 4. Relier le serveur à l'App Store | Render + App Store Connect | 10 min |
| 5. TestFlight | Xcode + App Store Connect | 20 min |
| 6. Soumettre à Apple | App Store Connect | 20 min |

> **Pourquoi un serveur ?** Une clé OpenAI embarquée dans une app iPhone peut être extraite en quelques
> minutes, et n'importe qui pourrait alors la vider. Les « variables d'environnement » d'Xcode n'existent que
> quand l'app est lancée depuis Xcode : elles disparaissent sur TestFlight et sur l'App Store. La clé vit
> donc dans une **variable d'environnement du serveur** (`OPENAI_API_KEY`). Le serveur fait aussi respecter
> l'essai et les quotas de chaque formule : c'est ce qui empêche quelqu'un de consommer vos tokens.

---

## 0. Prérequis

- Un **Mac** avec **Xcode 26** ou plus récent (App Store → Xcode). Apple exige le SDK iOS 26 pour publier.
- Un compte **Apple Developer Program** (99 €/an) : <https://developer.apple.com/programs/>.
- Dans App Store Connect → **Business** : le contrat **Paid Apps** signé, avec les informations bancaires
  et fiscales remplies. Sans cela, les abonnements ne s'affichent pas, même en test.
- Une **clé API OpenAI** avec du crédit. Dans <https://platform.openai.com> → *Limits*, fixez un **budget
  mensuel maximum** : c'est votre filet de sécurité.
- Le projet doit autoriser les modèles `gpt-transcribe`, `gpt-4o-transcribe-diarize`, `gpt-6-sol` et
  `gpt-6-astra`. Si Sol n'est pas activé, le serveur bascule tout seul sur Astra.
- Ce repo, cloné ou téléchargé sur le Mac.

## 1. Déployer le serveur

### Option A : Render (recommandée, ~10 $/mois)

1. <https://dashboard.render.com> → **New → Blueprint** → connectez GitHub → choisissez ce repo.
   Render lit `render.yaml` : un service web Docker et un disque de 10 Go.
2. Render demande les variables marquées « sync: false » :
   - `OPENAI_API_KEY` : votre clé OpenAI.
   - `OPERATOR_NAME` : votre nom ou celui de votre société (il apparaît dans la politique de confidentialité).
   - `CONTACT_EMAIL` : l'adresse de support affichée aux utilisateurs.
   - `APPLE_APP_ID` : **laissez vide pour l'instant** (étape 4).
   - `APNS_*` : laissez vide pour l'instant (étape 4, optionnel).
3. **Apply**. Après 3 à 5 minutes, l'URL du service s'affiche, par exemple `https://parley-api-x1y2.onrender.com`.
4. Vérifiez dans un navigateur :
   - `https://…/healthz` répond `{"ok": true, …}`.
   - `https://…/legal/privacy` affiche la politique de confidentialité (FR ou EN selon le navigateur).

`SECRET_KEY` et `ADMIN_TOKEN` sont générés automatiquement. `ADMIN_TOKEN` donne accès à
`GET /admin/stats` : abonnés, heures transcrites, coût OpenAI estimé.

### Option B : n'importe quel hébergeur Docker (Railway, Fly.io, VPS…)

```bash
cd server
docker build -t parley-api .
docker run -d -p 8000:8000 -v parley-data:/data \
  -e OPENAI_API_KEY=sk-... -e SECRET_KEY=une-longue-chaine-aleatoire \
  -e OPERATOR_NAME="Votre nom" -e CONTACT_EMAIL=support@exemple.com \
  parley-api
```

Contraintes :
- montez un **volume persistant sur `/data`** (base SQLite et audio en cours de traitement) ;
- servez l'app en **HTTPS**, car iOS refuse le HTTP simple ;
- lancez **une seule instance**. Toutes les variables sont documentées dans `server/.env.example`.

Avec Railway : *New project → Deploy from GitHub*, *Root directory* = `server`, ajoutez un *Volume* monté
sur `/data`, puis les variables.

## 2. Configurer et lancer l'app

1. Ouvrez **`ios/Config/Parley.xcconfig`**, le seul fichier à modifier :
   ```
   PARLEY_BUNDLE_ID = com.thomasbacos.parley      // à garder, sauf si déjà pris
   DEVELOPMENT_TEAM = ABCDE12345                  // developer.apple.com → Membership → Team ID
   PARLEY_API_BASE_URL = https:/$()/parley-api-x1y2.onrender.com   // votre URL Render
   ```
   (Le `$()` entre les deux `/` est voulu : dans ce type de fichier, `//` commence un commentaire.)
2. Double-cliquez sur **`ios/Parley.xcodeproj`**. Xcode s'ouvre ; laissez-le indexer une minute.
3. Choisissez la cible **Parley** → onglet **Signing & Capabilities** et vérifiez que l'équipe est bien
   sélectionnée. Faites de même pour la cible **ParleyWidgets**. Xcode crée seul les identifiants et
   active les capacités (notifications push, Live Activities).
4. Branchez votre iPhone, choisissez-le en haut de la fenêtre, puis **▶ Run**. La première fois, sur
   l'iPhone : *Réglages → Général → VPN et gestion de l'appareil* pour faire confiance au certificat
   développeur, et *Réglages → Confidentialité → Mode développeur* à activer.

**Tester sans App Store Connect (simulateur)** : le scheme utilise `ios/Config/Products.storekit`, des
abonnements fictifs avec essai de 7 jours. Les achats y sont signés par Xcode et non par Apple. Pour que
votre serveur de développement les accepte, ajoutez `Xcode` à `APPLE_ENVIRONMENTS`
(`Xcode,Sandbox,Production`). **Ne le faites jamais sur le serveur de production.** Le plus simple est de
lancer un serveur local :

```bash
cd server && cp .env.example .env    # mettre OPENAI_API_KEY et APPLE_ENVIRONMENTS=Xcode,Sandbox
docker compose up --build           # API sur http://localhost:8000
```
puis de mettre `PARLEY_API_BASE_URL = http:/$()/localhost:8000` le temps des tests en simulateur.

Si l'écran d'abonnement n'affiche aucune formule dans le simulateur : *Product → Scheme → Edit Scheme →
Run → Options → StoreKit Configuration* → sélectionnez `Products.storekit`.

## 3. App Store Connect : l'app et les abonnements

<https://appstoreconnect.apple.com> → **Apps → +  Nouvelle app**

- Plateforme iOS, nom **Parley** (s'il est pris, par exemple « Parley – Notes de réunion »), langue
  principale Français, identifiant de bundle = `PARLEY_BUNDLE_ID`, SKU `parley-ios`.

**Abonnements** (*Monétisation → Abonnements*) :

1. Créez un **groupe d'abonnements** nommé `Parley`.
2. Créez **3 abonnements** avec **exactement** ces identifiants de produit :

   | Référence | ID produit | Durée | Prix (France) | Niveau |
   |---|---|---|---|---|
   | Essentiel mensuel | `com.thomasbacos.parley.essential.monthly` | 1 mois | 6,99 € | 2 |
   | Pro mensuel | `com.thomasbacos.parley.pro.monthly` | 1 mois | 14,99 € | 1 |
   | Pro annuel | `com.thomasbacos.parley.pro.yearly` | 1 an | 129,99 € | 1 |

   Si vous avez changé le bundle ID, gardez la même fin (`.essential.monthly`, etc.) : l'app et le serveur
   reconnaissent les formules à ce suffixe.
3. Pour chaque abonnement :
   - **Localisation** FR et EN : nom affiché (« Essentiel », « Pro », « Pro (annuel) ») et description,
     par exemple « 4 h de transcription par mois » ou « 10 h de transcription par mois ».
   - **Offre de lancement** : *Gratuit*, *1 semaine*, tous les pays. C'est l'essai de 7 jours. Apple ne
     l'accorde qu'une fois par identifiant Apple ; le serveur le plafonne à 60 min d'audio.
   - **Informations pour la vérification** : une capture de l'écran d'abonnement (prise à l'étape 5).
4. *Informations sur l'app* :
   - **URL de la politique de confidentialité** = `https://<votre serveur>/legal/privacy`
   - **URL d'assistance** (dans la fiche de version) = `https://<votre serveur>/support`
5. *Confidentialité de l'app* : déclarez les données comme indiqué dans `docs/APP_STORE.md`.
6. Notez l'**identifiant Apple** de l'app (*Informations sur l'app → Informations générales → Identifiant
   Apple*, un nombre comme `6739123456`).

## 4. Relier le serveur à l'App Store

Sur Render → votre service → **Environment** :

- `APPLE_APP_ID` = l'identifiant Apple de l'étape 3. Il est indispensable pour vérifier les vrais achats.
- *(Recommandé)* **Notifications « c'est prêt »** : sur developer.apple.com → *Certificates, IDs & Profiles →
  Keys → +* → cochez *Apple Push Notifications service (APNs)* → téléchargez le `.p8`. Puis renseignez
  `APNS_KEY_ID` (l'identifiant de la clé), `APNS_TEAM_ID` (votre Team ID) et `APNS_PRIVATE_KEY` (le contenu
  du `.p8`, collé tel quel).

Dans App Store Connect → *Informations sur l'app → Notifications du serveur App Store* : saisissez
`https://<votre serveur>/v1/appstore/notifications` en version 2, pour la **production** et pour le
**sandbox**. Le serveur apprend ainsi les remboursements et les renouvellements.

## 5. TestFlight

1. Dans Xcode, choisissez la destination **Any iOS Device (arm64)**, puis **Product → Archive**.
2. L'Organizer s'ouvre : **Distribute App → App Store Connect → Upload**, en gardant les options par défaut.
3. Après 10 à 20 min de traitement, le build apparaît dans App Store Connect → **TestFlight**. Ajoutez-vous
   comme testeur interne et installez l'app avec l'app TestFlight.
4. Testez le parcours complet : enregistrer en verrouillant l'écran, passer un appel (l'enregistrement se
   met en pause puis reprend), arrêter depuis l'écran verrouillé, démarrer l'essai (sur TestFlight, les
   achats sont fictifs et gratuits), transcrire, recevoir la notification, exporter en PDF.
5. Pour chaque nouvel envoi, augmentez `CURRENT_PROJECT_VERSION` dans `Parley.xcconfig` (2, 3, 4…).

## 6. Soumettre à Apple

1. **Captures d'écran** : iPhone 6,9" (1320 × 2868), au moins 3. Utilisez le simulateur *iPhone 17 Pro Max*
   avec *File → Save Screen*. Les écrans à montrer et les textes de la fiche sont dans `docs/APP_STORE.md`.
2. Remplissez la fiche (description, mots-clés, catégorie Productivité, âge 4+), choisissez le build, puis
   **attachez les 3 abonnements** à la version. Les premiers abonnements doivent être soumis avec une
   version de l'app.
3. **Notes pour l'équipe de vérification** : collez le texte prêt dans `docs/APP_STORE.md`. Il explique
   l'usage de l'audio en arrière-plan et l'absence de compte à créer.
4. **Soumettre pour vérification.**

## Exploitation

| Besoin | Comment |
|---|---|
| Changer les quotas (minutes) | Variables `PLAN_TRIAL_MINUTES`, `PLAN_ESSENTIAL_MINUTES`, `PLAN_PRO_MINUTES` (+ `*_MAX_FILE_MINUTES`) sur Render. Pas de mise à jour de l'app nécessaire. |
| Changer les prix | App Store Connect → Abonnements → Prix |
| Voir l'activité | `curl -H "X-Admin-Token: …" https://<serveur>/admin/stats` |
| Changer de modèle | `TRANSCRIBE_MODEL`, `DIARIZE_MODEL`, `LLM_MODEL`, `LLM_FALLBACK_MODEL` |
| Plus de capacité | `WORKERS` (transcriptions simultanées, 3 par défaut), puis un plan Render plus gros |
| Logs | Render → service → Logs |

**Économie** (estimations, à ajuster avec votre facture OpenAI) : environ 1 $ par heure d'audio (texte +
intervenants + correction + résumé). Apple garde 15 % (programme petites entreprises, à demander) et la TVA
s'applique.

| Formule | Prix TTC | Net estimé (après TVA et 15 %) | Coût max à quota plein |
|---|---|---|---|
| Essai 7 j | 0 € | 0 € | ~1 $ (60 min) |
| Essentiel | 6,99 €/mois | ~4,95 € | ~4 $ (4 h) |
| Pro | 14,99 €/mois | ~10,60 € | ~10 $ (10 h) |
| Pro annuel | 129,99 €/an | ~7,65 €/mois | ~10 $/mois |

La plupart des abonnés n'utilisent pas tout leur quota. Si vos chiffres réels le demandent, baissez
`PLAN_PRO_MINUTES` ou augmentez les prix.
