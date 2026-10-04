import Foundation

/// Screenshot mode, used by CI to produce App Store screenshots:
///     -ParleyDemo -ParleyScreen home|summary|transcript|recorder|paywall|onboarding
/// Seeds realistic sample recordings and opens the requested screen. Inactive without the argument.
enum Demo {
    static let isActive = ProcessInfo.processInfo.arguments.contains("-ParleyDemo")

    static var screen: String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-ParleyScreen"), i + 1 < args.count { return args[i + 1] }
        return "home"
    }

    static let meetingID = UUID(uuidString: "6F1D2C3B-0000-4000-8000-000000000001")!
    private static var french: Bool { Locale.current.language.languageCode?.identifier == "fr" }

    @MainActor
    static func apply(_ model: AppModel) {
        guard isActive else { return }
        Prefs.onboarded = screen != "onboarding"
        model.store.deleteAll()
        seed(model.store)
        model.subscriptions.useDemoAccount()
        switch screen {
        case "summary", "transcript":
            model.path = [meetingID]
        case "recorder":
            model.recorder.startDemo(title: french ? "Comité de direction" : "Leadership meeting")
            model.showRecorder = true
        case "paywall":
            model.showPaywall = true
        default:
            break
        }
    }

    private static func ago(_ hours: Double) -> Date { Date().addingTimeInterval(-hours * 3600) }

    @MainActor
    private static func seed(_ store: RecordingStore) {
        let fr = french
        var meeting = Recording(id: meetingID, title: fr ? "Lancement de l'app — point d'équipe" : "App launch — team sync",
                                createdAt: ago(1.5), duration: 2832, audioFile: "audio.m4a", source: .microphone,
                                markers: [612, 1904], status: .done)
        meeting.hasResult = true
        meeting.titleIsCustom = true
        meeting.doneActions = [1]
        store.save(meeting)
        if let data = try? JSONSerialization.data(withJSONObject: result(fr)) {
            _ = try? store.saveResult(data, for: meetingID)
        }

        var lecture = Recording(id: UUID(), title: fr ? "Cours de stratégie — chapitre 3" : "Strategy class — chapter 3",
                                createdAt: ago(0.2), duration: 5410, audioFile: "audio.m4a", source: .microphone,
                                status: .processing)
        lecture.stage = "speakers"
        lecture.progress = 0.58
        lecture.jobID = "demo"
        store.save(lecture)

        var interview = Recording(id: UUID(), title: fr ? "Entretien — Product designer" : "Interview — Product designer",
                                  createdAt: ago(26), duration: 2405, audioFile: "audio.m4a", source: .microphone,
                                  status: .done)
        interview.hasResult = true
        store.save(interview)

        store.save(Recording(id: UUID(), title: fr ? "Idées podcast" : "Podcast ideas", createdAt: ago(50),
                             duration: 312, audioFile: "audio.m4a", source: .microphone, status: .local))
        store.save(Recording(id: UUID(), title: fr ? "Conférence client.mp4" : "Client conference.mp4",
                             createdAt: ago(120), duration: 3920, audioFile: "audio.m4a", source: .imported,
                             status: .done, hasResult: true))
    }

    private static func frTurns() -> [[String: Any]] {
        return [
            ["spk": "A", "start": 4.0, "end": 21.0, "text": "Bonjour à tous. Je m'appelle Claire, je pilote le lancement. L'objectif aujourd'hui : valider la date de sortie et le budget marketing."],
            ["spk": "B", "start": 22.5, "end": 41.0, "text": "Côté technique on est prêts. La version 1.0 est sur TestFlight depuis lundi, avec 48 testeurs et aucun crash remonté."],
            ["spk": "C", "start": 42.0, "end": 63.0, "text": "Les retours sont très bons sur l'enregistrement écran verrouillé. Deux personnes demandent l'export vers Notion, c'est déjà prévu."],
            ["spk": "A", "start": 64.0, "end": 80.0, "text": "Parfait. Julien, est-ce qu'on peut tenir le 14 novembre pour la soumission à Apple ?"],
            ["spk": "B", "start": 81.0, "end": 102.0, "text": "Oui, si les captures d'écran et la fiche sont prêtes d'ici le 7. Il faut compter deux jours de validation."],
            ["spk": "C", "start": 103.0, "end": 125.0, "text": "Je m'occupe de la fiche App Store en français et en anglais. Pour le budget, je propose 8 000 euros sur le premier mois."],
            ["spk": "A", "start": 126.0, "end": 140.0, "text": "D'accord pour 8 000 euros, avec un point à mi-parcours sur le coût par essai."],
        ]
    }

    private static func enTurns() -> [[String: Any]] {
        return [
            ["spk": "A", "start": 4.0, "end": 21.0, "text": "Hi everyone. I'm Claire, I'm running the launch. Today we need to lock the release date and the marketing budget."],
            ["spk": "B", "start": 22.5, "end": 41.0, "text": "Engineering is ready. Version 1.0 has been on TestFlight since Monday, 48 testers and zero crashes reported."],
            ["spk": "C", "start": 42.0, "end": 63.0, "text": "Feedback on lock-screen recording is great. Two people asked for a Notion export, which is already planned."],
            ["spk": "A", "start": 64.0, "end": 80.0, "text": "Perfect. Julien, can we hold November 14 for the App Store submission?"],
            ["spk": "B", "start": 81.0, "end": 102.0, "text": "Yes, if the screenshots and the listing are ready by the 7th. Review takes about two days."],
            ["spk": "C", "start": 103.0, "end": 125.0, "text": "I'll write the App Store listing in English and French. For the budget I suggest 8,000 euros for the first month."],
            ["spk": "A", "start": 126.0, "end": 140.0, "text": "8,000 euros it is, with a mid-month check on cost per trial."],
        ]
    }

    private static func frSummary() -> [String: Any] {
        return [
            "kind": "meeting", "title": "Lancement de l'app — point d'équipe",
            "subtitle": "Claire, Julien et Sofia valident la date de soumission et le budget de lancement.",
            "sections": [
                ["head": "Points clés", "bullets": [
                    "La version 1.0 est stable : 48 testeurs sur TestFlight, aucun crash remonté.",
                    "Soumission à Apple fixée au 14 novembre, sous réserve d'une fiche prête le 7.",
                    "Budget marketing du premier mois validé à 8 000 €.",
                    "L'export Notion, demandé par les testeurs, est déjà planifié."]],
                ["head": "Retours des testeurs", "bullets": [
                    "L'enregistrement écran verrouillé est la fonctionnalité la plus appréciée.",
                    "Deux demandes d'export vers Notion."]],
                ["head": "Calendrier", "bullets": [
                    "7 novembre : captures d'écran et fiche App Store prêtes.",
                    "14 novembre : soumission, environ deux jours de validation."]],
            ],
            "actions": [
                ["task": "Rédiger la fiche App Store FR et EN", "owner": "Sofia", "due": "7 novembre"],
                ["task": "Préparer les captures d'écran", "owner": "Julien", "due": "7 novembre"],
                ["task": "Point à mi-parcours sur le coût par essai", "owner": "Claire", "due": "fin novembre"],
            ],
        ]
    }

    private static func enSummary() -> [String: Any] {
        return [
            "kind": "meeting", "title": "App launch — team sync",
            "subtitle": "Claire, Julien and Sofia lock the submission date and the launch budget.",
            "sections": [
                ["head": "Key takeaways", "bullets": [
                    "Version 1.0 is stable: 48 TestFlight testers, zero crashes reported.",
                    "App Store submission set for November 14, if the listing is ready by the 7th.",
                    "First-month marketing budget approved at 8,000 euros.",
                    "Notion export, requested by testers, is already planned."]],
                ["head": "Tester feedback", "bullets": [
                    "Lock-screen recording is the most loved feature.",
                    "Two requests for a Notion export."]],
                ["head": "Timeline", "bullets": [
                    "November 7: screenshots and App Store listing ready.",
                    "November 14: submission, about two days of review."]],
            ],
            "actions": [
                ["task": "Write the App Store listing (EN + FR)", "owner": "Sofia", "due": "Nov 7"],
                ["task": "Prepare the screenshots", "owner": "Julien", "due": "Nov 7"],
                ["task": "Mid-month check on cost per trial", "owner": "Claire", "due": "end of November"],
            ],
        ]
    }

    private static func result(_ fr: Bool) -> [String: Any] {
        let allTurns = fr ? frTurns() : enTurns()
        let summary = fr ? frSummary() : enSummary()
        let text = allTurns.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        let names: [String: String] = ["A": "Claire", "B": "Julien", "C": "Sofia"]
        let corrections: [[String: String]] = [
            ["from": "Parlé", "to": "Parley", "why": fr ? "nom du produit" : "product name"],
            ["from": "test flight", "to": "TestFlight", "why": fr ? "glossaire" : "glossary"],
        ]
        var out: [String: Any] = [:]
        out["version"] = 1
        out["duration"] = 2832.0
        out["language"] = fr ? "fr" : "en"
        out["languages"] = [fr ? "fr" : "en"]
        out["title"] = summary["title"] as? String ?? ""
        out["text"] = text
        out["turns"] = allTurns
        out["names"] = names
        out["summary"] = summary
        out["corrections"] = corrections
        out["warnings"] = [String]()
        out["word_count"] = 9120
        return out
    }
}
