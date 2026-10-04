import AppIntents
import Foundation

/// Bridge between the Live Activity buttons and the recorder. `LiveActivityIntent`s run in the app's
/// process, where the recorder registers these handlers; in the widget process they stay nil.
@MainActor
final class RecordingControl {
    static let shared = RecordingControl()
    var togglePause: (() -> Void)?
    var stop: (() -> Void)?
    var addMarker: (() -> Void)?
}

struct TogglePauseRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or resume recording"

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { RecordingControl.shared.togglePause?() }
        return .result()
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop recording"

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { RecordingControl.shared.stop?() }
        return .result()
    }
}

struct AddMarkerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark this moment"

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { RecordingControl.shared.addMarker?() }
        return .result()
    }
}
