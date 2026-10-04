# Parley

**App iPhone** qui enregistre réunions, cours et entretiens (même écran verrouillé), puis donne la
transcription, qui a dit quoi, un résumé avec les actions à mener, et des exports PDF / Markdown. Elle
s'accompagne d'un **serveur** qui détient la clé OpenAI, fait le travail de transcription et applique
l'essai gratuit et les abonnements.

[![iOS build](https://github.com/thomasbacos/app_transcript_test/actions/workflows/ios.yml/badge.svg)](https://github.com/thomasbacos/app_transcript_test/actions/workflows/ios.yml)
[![Server tests](https://github.com/thomasbacos/app_transcript_test/actions/workflows/server.yml/badge.svg)](https://github.com/thomasbacos/app_transcript_test/actions/workflows/server.yml)

| | |
|---|---|
| **Mettre en ligne (pas à pas)** | [`docs/DEPLOIEMENT.md`](docs/DEPLOIEMENT.md) |
| **Textes de la fiche App Store, confidentialité, notes de vérification** | [`docs/APP_STORE.md`](docs/APP_STORE.md) |
| **Comment c'est construit** | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| **Captures d'écran (générées par la CI)** | branche [`screenshots`](https://github.com/thomasbacos/app_transcript_test/tree/screenshots) |

## En bref

```
iPhone (SwiftUI)                         Serveur (FastAPI, Docker)                OpenAI
──────────────────                       ─────────────────────────                ──────
enregistre (arrière-plan)  ──audio──▶    vérifie l'abonnement Apple
importe audio / vidéo                    applique essai + quotas      ──────▶    gpt-transcribe
Live Activity, Siri                      découpe, parallélise         ──────▶    gpt-4o-transcribe-diarize
StoreKit 2 (essai 7 j)                   corrige, résume              ──────▶    gpt-6-sol / astra
résumé, transcription,     ◀─résultat─   supprime l'audio
exports PDF/MD/SRT                       notification push « c'est prêt »
```

- **La clé OpenAI** est une variable d'environnement du serveur (`OPENAI_API_KEY`). Elle n'est jamais dans
  l'app ni dans le repo.
- **Offres** : essai gratuit de 7 jours (60 min), **Essentiel** 6,99 €/mois (4 h), **Pro** 14,99 €/mois ou
  129,99 €/an (10 h/mois). Les quotas se règlent côté serveur sans mettre l'app à jour.
- **Langues de l'interface** : français et anglais. La transcription couvre plus de 20 langues, détectées
  automatiquement.

## Ce que vous avez à faire

1. Déployer le serveur sur Render (15 min) → [DEPLOIEMENT §1](docs/DEPLOIEMENT.md#1-déployer-le-serveur).
2. Mettre l'URL du serveur et votre Team ID dans `ios/Config/Parley.xcconfig`, puis ouvrir
   `ios/Parley.xcodeproj` dans Xcode 26 et lancer l'app.
3. Créer l'app et les 3 abonnements dans App Store Connect, puis passer par TestFlight et soumettre
   (§3 à §6).

## Structure

```
ios/
  Parley.xcodeproj         projet Xcode (groupes synchronisés : tout fichier ajouté est compilé)
  Config/                  Parley.xcconfig (LE fichier à modifier), Info.plist, entitlements, Products.storekit
  Parley/                  l'app : App/, Models/, Services/, Views/, Resources/ (icône, FR/EN, confidentialité)
  ParleyWidgets/           extension Live Activity (écran verrouillé + Dynamic Island)
  Shared/                  code commun app + extension (attributs Live Activity, intents pause/stop/repère)
server/
  app/                     API, comptes et quotas, vérification App Store, jobs, push, pages légales
  app/pipeline/            transcription (portage de l'app Windows), correction, résumé, documents
  tests/                   tests de bout en bout avec un faux OpenAI (python -m pytest)
  Dockerfile, .env.example, docker-compose.yml
render.yaml                déploiement Render en un clic
scripts/                   icône, traductions (build_strings.py), génération du projet Xcode
.github/workflows/         CI : build iOS (macOS 26), tests serveur + Docker, captures d'écran
```

## Développement

```bash
# serveur
cd server && python -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt pytest
python -m pytest -q                 # 19 tests : pipeline, essai, quotas, abus, reprise après panne, remboursements
uvicorn app.main:app --reload       # http://localhost:8000

# app : ouvrir ios/Parley.xcodeproj dans Xcode 26
python scripts/build_strings.py     # après avoir ajouté du texte dans l'app : régénère les traductions FR/EN
```
