"""
Public pages: privacy policy, terms, support. App Store Connect requires a privacy policy URL and a
support URL, and subscription apps must link both from the app: these pages are served by the API itself
(https://<your server>/legal/privacy ...), filled with OPERATOR_NAME and CONTACT_EMAIL.

These texts are a solid starting point, not legal advice: have them reviewed for your situation.
"""
import html

from .config import get_settings

CSS = """
:root{--bg:#fbfaff;--fg:#1d1b2e;--muted:#5d5a73;--accent:#5b4bdb;--card:#fff;--line:#e7e4f3}
@media (prefers-color-scheme:dark){:root{--bg:#0f0e17;--fg:#ecebf5;--muted:#a9a6bf;--accent:#9d8cff;--card:#18172a;--line:#2a2840}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:760px;margin:0 auto;padding:40px 16px 80px}h1{font-size:30px;line-height:1.2;margin:0 0 6px}
h2{font-size:19px;margin:32px 0 8px}p,li{color:var(--fg)}.muted{color:var(--muted);font-size:14px}
a{color:var(--accent)}.brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:18px;margin-bottom:28px}
.dot{width:28px;height:28px;border-radius:8px;background:linear-gradient(135deg,#5b4bdb,#c04bd8 60%,#ff7a8a)}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px 20px;margin:16px 0}
nav a{margin-right:16px;font-size:14px}
"""

T = {
    "fr": {
        "nav": ("Confidentialité", "Conditions", "Assistance"),
        "home_title": "Parley",
        "home": """<p>Parley enregistre vos réunions, cours et entretiens, même écran verrouillé, puis vous
donne la transcription, qui a dit quoi, et un résumé avec les actions à mener.</p>
<p class="muted">Disponible sur l'App Store pour iPhone.</p>""",
        "privacy_title": "Politique de confidentialité",
        "privacy": """
<p class="muted">Dernière mise à jour : 4 octobre 2026</p>
<p>{op} (« nous ») édite l'application Parley. Cette politique explique quelles données sont traitées,
pourquoi, et combien de temps. Nous collectons le strict minimum nécessaire au service.</p>
<h2>1. Ce que nous ne faisons pas</h2>
<ul><li>Pas de compte, pas d'e-mail, pas de nom demandé.</li><li>Pas de publicité, pas de traçage, pas de
revente de données.</li><li>Vos enregistrements ne servent pas à entraîner des modèles d'IA.</li></ul>
<h2>2. Données traitées</h2>
<ul>
<li><b>Enregistrements audio</b> que vous choisissez de transcrire, et les <b>documents de référence</b>
éventuels que vous joignez : envoyés à notre serveur, transmis à notre sous-traitant OpenAI pour la
transcription, puis <b>supprimés dès la fin du traitement</b> (au plus tard 24 h après un échec).</li>
<li><b>Transcriptions et résumés</b> : conservés sur le serveur uniquement le temps que l'application les
récupère, puis supprimés (au plus tard 72 h). Ensuite ils ne sont stockés que sur votre iPhone.</li>
<li><b>Informations d'abonnement</b> : la preuve d'achat signée par Apple (identifiant de transaction,
produit, dates). Nous ne recevons ni votre nom, ni votre e-mail, ni vos coordonnées bancaires.</li>
<li><b>Identifiants techniques</b> : un identifiant aléatoire d'installation, le jeton de notification push
(si vous les autorisez), la langue de l'appareil, la version de l'app.</li>
<li><b>Compteur d'utilisation</b> : minutes transcrites par période, pour appliquer votre forfait.</li>
</ul>
<p>Les enregistrements non transcrits restent sur votre iPhone et ne nous sont jamais envoyés.</p>
<h2>3. Finalités et bases légales</h2>
<p>Fournir le service que vous demandez (exécution du contrat), appliquer les limites de votre forfait
et prévenir les abus (intérêt légitime), respecter nos obligations légales.</p>
<h2>4. Sous-traitants</h2>
<ul><li><b>OpenAI</b> (transcription, identification des locuteurs, correction et résumé). Les données
envoyées via l'API ne sont pas utilisées pour entraîner leurs modèles.</li>
<li><b>Notre hébergeur</b> (serveur et base de données).</li>
<li><b>Apple</b> (paiements, abonnements, notifications push).</li></ul>
<p>Certains de ces prestataires peuvent traiter des données hors de l'Union européenne, avec les garanties
prévues par le RGPD (clauses contractuelles types).</p>
<h2>5. Votre responsabilité lors d'un enregistrement</h2>
<p>Informez les personnes enregistrées et obtenez leur accord lorsque la loi l'exige.</p>
<h2>6. Vos droits</h2>
<p>Vous pouvez supprimer à tout moment vos enregistrements dans l'app, et toutes les données serveur via
<b>Réglages → Supprimer mes données serveur</b>. Pour tout droit d'accès, de rectification, d'effacement,
d'opposition ou de portabilité : <a href="mailto:{mail}">{mail}</a>. Vous pouvez aussi saisir la CNIL.</p>
<h2>7. Enfants</h2><p>Le service n'est pas destiné aux moins de 15 ans.</p>
<h2>8. Contact</h2><p>{op} — <a href="mailto:{mail}">{mail}</a></p>
""",
        "terms_title": "Conditions d'utilisation",
        "terms": """
<p class="muted">Dernière mise à jour : 4 octobre 2026</p>
<p>L'utilisation de Parley est régie par le
<a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">contrat de licence standard
d'Apple (EULA)</a>, complété par les conditions ci-dessous.</p>
<h2>Abonnements</h2>
<ul><li>Parley propose des abonnements mensuels et annuels avec renouvellement automatique, et un essai
gratuit de 7 jours pour les nouveaux abonnés.</li>
<li>Le paiement est débité sur votre compte Apple à la confirmation de l'achat (à la fin de l'essai le cas
échéant). L'abonnement se renouvelle automatiquement sauf s'il est désactivé au moins 24 h avant la fin de
la période en cours, depuis les réglages de votre compte Apple.</li>
<li>Chaque formule inclut un nombre de minutes de transcription par mois (par essai pour l'essai gratuit),
affiché dans l'app. Les minutes non utilisées ne sont pas reportées.</li></ul>
<h2>Usage acceptable</h2>
<p>Vous êtes responsable des enregistrements que vous réalisez et devez respecter les lois sur la vie
privée et le consentement des personnes enregistrées.</p>
<h2>Résultats générés par l'IA</h2>
<p>Les transcriptions et résumés sont produits automatiquement et peuvent contenir des erreurs. Vérifiez
les noms, chiffres et citations avant toute utilisation importante.</p>
<h2>Contact</h2><p>{op} — <a href="mailto:{mail}">{mail}</a></p>
""",
        "support_title": "Assistance",
        "support": """
<p>Une question, un problème d'abonnement ou une transcription inattendue ? Écrivez-nous :
<a href="mailto:{mail}">{mail}</a>. Nous répondons sous 2 jours ouvrés.</p>
<div class="card"><b>L'enregistrement s'arrête-t-il si je verrouille l'iPhone ?</b><br>Non. Parley continue
d'enregistrer en arrière-plan ; un minuteur reste visible sur l'écran verrouillé et dans la Dynamic Island.
Un appel téléphonique met l'enregistrement en pause ; il reprend automatiquement après.</div>
<div class="card"><b>Puis-je fermer l'app pendant la transcription ?</b><br>Oui. Le traitement a lieu sur
nos serveurs ; vous recevez une notification quand c'est prêt.</div>
<div class="card"><b>Comment annuler mon abonnement ?</b><br>Réglages de l'iPhone → votre nom →
Abonnements → Parley, ou depuis l'app : Réglages → Gérer l'abonnement.</div>
<div class="card"><b>Les noms propres sont mal écrits.</b><br>Ajoutez-les dans « Termes et noms attendus »
avant de transcrire, ou joignez un document de référence (ordre du jour, présentation).</div>
""",
    },
    "en": {
        "nav": ("Privacy", "Terms", "Support"),
        "home_title": "Parley",
        "home": """<p>Parley records your meetings, lectures and interviews, even with the screen locked, then
gives you the transcript, who said what, and a summary with the action items.</p>
<p class="muted">Available on the App Store for iPhone.</p>""",
        "privacy_title": "Privacy policy",
        "privacy": """
<p class="muted">Last updated: October 4, 2026</p>
<p>{op} ("we") publishes the Parley app. This policy explains what data is processed, why, and for how
long. We collect the strict minimum needed to provide the service.</p>
<h2>1. What we do not do</h2>
<ul><li>No account, no email, no name required.</li><li>No advertising, no tracking, no selling of
data.</li><li>Your recordings are not used to train AI models.</li></ul>
<h2>2. Data we process</h2>
<ul>
<li><b>Audio recordings</b> you choose to transcribe, and any <b>reference documents</b> you attach: sent to
our server, passed to our processor OpenAI for transcription, then <b>deleted as soon as processing
ends</b> (at most 24 h after a failure).</li>
<li><b>Transcripts and summaries</b>: kept on the server only until the app downloads them, then deleted
(at most 72 h). After that they are stored only on your iPhone.</li>
<li><b>Subscription information</b>: Apple's signed proof of purchase (transaction id, product, dates). We
never receive your name, email or payment details.</li>
<li><b>Technical identifiers</b>: a random install id, the push notification token (if you allow
notifications), device language, app version.</li>
<li><b>Usage counter</b>: minutes transcribed per period, to apply your plan.</li>
</ul>
<p>Recordings you do not transcribe stay on your iPhone and are never sent to us.</p>
<h2>3. Purposes and legal bases</h2>
<p>Providing the service you request (contract), applying plan limits and preventing abuse (legitimate
interest), complying with legal obligations.</p>
<h2>4. Processors</h2>
<ul><li><b>OpenAI</b> (transcription, speaker identification, correction and summary). Data sent through
their API is not used to train their models.</li><li><b>Our hosting provider</b> (server and
database).</li><li><b>Apple</b> (payments, subscriptions, push notifications).</li></ul>
<h2>5. Your responsibility when recording</h2>
<p>Tell the people you record and get their consent where the law requires it.</p>
<h2>6. Your rights</h2>
<p>You can delete recordings in the app at any time, and all server-side data via <b>Settings → Delete my
server data</b>. For access, correction, erasure, objection or portability requests:
<a href="mailto:{mail}">{mail}</a>.</p>
<h2>7. Children</h2><p>The service is not intended for children under 15.</p>
<h2>8. Contact</h2><p>{op} — <a href="mailto:{mail}">{mail}</a></p>
""",
        "terms_title": "Terms of use",
        "terms": """
<p class="muted">Last updated: October 4, 2026</p>
<p>Use of Parley is governed by Apple's
<a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">standard licensed application
end user license agreement (EULA)</a>, supplemented by the terms below.</p>
<h2>Subscriptions</h2>
<ul><li>Parley offers auto-renewable monthly and yearly subscriptions, with a 7-day free trial for new
subscribers.</li><li>Payment is charged to your Apple account at confirmation of purchase (at the end of
the trial, if any). The subscription renews automatically unless turned off at least 24 hours before the
end of the current period, in your Apple account settings.</li>
<li>Each plan includes a number of transcription minutes per month (per trial for the free trial), shown
in the app. Unused minutes do not roll over.</li></ul>
<h2>Acceptable use</h2>
<p>You are responsible for the recordings you make and must comply with privacy and consent laws.</p>
<h2>AI-generated output</h2>
<p>Transcripts and summaries are generated automatically and may contain errors. Check names, figures and
quotes before relying on them.</p>
<h2>Contact</h2><p>{op} — <a href="mailto:{mail}">{mail}</a></p>
""",
        "support_title": "Support",
        "support": """
<p>A question, a subscription issue or an unexpected transcript? Email us:
<a href="mailto:{mail}">{mail}</a>. We answer within 2 business days.</p>
<div class="card"><b>Does recording stop when I lock my iPhone?</b><br>No. Parley keeps recording in the
background; a timer stays visible on the Lock Screen and in the Dynamic Island. A phone call pauses the
recording; it resumes automatically afterwards.</div>
<div class="card"><b>Can I close the app while it transcribes?</b><br>Yes. Processing happens on our
servers; you get a notification when it is ready.</div>
<div class="card"><b>How do I cancel my subscription?</b><br>iPhone Settings → your name → Subscriptions →
Parley, or in the app: Settings → Manage subscription.</div>
<div class="card"><b>Names are misspelled.</b><br>Add them under "Expected names and terms" before
transcribing, or attach a reference document (agenda, slides).</div>
""",
    },
}


def lang_of(request):
    q = request.query_params.get("lang")
    if q in T:
        return q
    al = (request.headers.get("accept-language") or "").lower()
    return "fr" if al.startswith("fr") else "en"


def page(kind, lang):
    s = get_settings()
    t = T[lang]
    body = t[kind].format(op=html.escape(s.operator_name), mail=html.escape(s.contact_email))
    nav = '<nav><a href="/legal/privacy?lang={l}">{a}</a><a href="/legal/terms?lang={l}">{b}</a>' \
          '<a href="/support?lang={l}">{c}</a></nav>'.format(l=lang, a=t["nav"][0], b=t["nav"][1], c=t["nav"][2])
    title = t[kind + "_title"]
    return """<!doctype html><html lang="{lang}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{title} · Parley</title>
<style>{css}</style></head><body><main><div class="brand"><span class="dot"></span>Parley</div>
<h1>{title}</h1>{body}<p style="margin-top:40px">{nav}</p></main></body></html>""".format(
        lang=lang, title=html.escape(title), css=CSS, body=body, nav=nav)
