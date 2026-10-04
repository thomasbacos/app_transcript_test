import AppIntents

/// "Hey Siri, record with Parley", Shortcuts app, Action button.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start recording"
    static let description = IntentDescription("Starts a new recording in Parley.")
    static let openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        model.handleOpenURL(URL(string: "parley://record")!)
        return .result()
    }
}

struct ParleyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Record with \(.applicationName)",
                              "Start recording with \(.applicationName)",
                              "Start a \(.applicationName) recording"],
                    shortTitle: "Record",
                    systemImageName: "mic.fill")
    }
}
