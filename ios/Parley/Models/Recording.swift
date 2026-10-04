import Foundation

enum RecordingStatus: String, Codable {
    case recording      // being recorded right now (or interrupted by a crash, recovered at launch)
    case saving         // compressing the audio after stop
    case local          // on the iPhone, not transcribed
    case uploading
    case processing
    case done
    case failed
}

struct ProcessingOptions: Codable, Hashable {
    var languages: [String] = []          // empty = automatic detection
    var terms: String = ""                // expected names and jargon, comma separated
    var speakers: Bool = true
    var correct: Bool = true
    var summary: Bool = true
    var summaryLanguage: String = "auto"  // "auto" = language of the recording

    var termList: [String] {
        terms.split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func payload() -> [String: Any] {
        [
            "languages": languages,
            "terms": termList,
            "speakers": speakers,
            "correct": correct,
            "summary": summary,
            "summary_language": summaryLanguage,
            "ui_language": Locale.current.language.languageCode?.identifier ?? "en",
        ]
    }
}

struct Recording: Codable, Identifiable, Hashable {
    enum Source: String, Codable { case microphone, imported }

    let id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval = 0
    var audioFile: String
    var source: Source
    var markers: [TimeInterval] = []
    var status: RecordingStatus
    var jobID: String?
    var stage: String?
    var progress: Double = 0
    var uploadProgress: Double = 0
    var errorCode: String?
    var errorMessage: String?
    var retryable: Bool = false
    var options: ProcessingOptions?
    var docNames: [String] = []
    var speakerNames: [String: String] = [:]
    var doneActions: Set<Int> = []
    var hasResult: Bool = false
    var titleIsCustom: Bool = false

    var isBusy: Bool { status == .uploading || status == .processing }
}

extension Recording {
    /// Tolerant decoding: files written by older versions of the app still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        audioFile = try c.decodeIfPresent(String.self, forKey: .audioFile) ?? "audio.m4a"
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .microphone
        markers = try c.decodeIfPresent([TimeInterval].self, forKey: .markers) ?? []
        status = try c.decodeIfPresent(RecordingStatus.self, forKey: .status) ?? .local
        jobID = try c.decodeIfPresent(String.self, forKey: .jobID)
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        uploadProgress = try c.decodeIfPresent(Double.self, forKey: .uploadProgress) ?? 0
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        retryable = try c.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
        options = try c.decodeIfPresent(ProcessingOptions.self, forKey: .options)
        docNames = try c.decodeIfPresent([String].self, forKey: .docNames) ?? []
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        doneActions = try c.decodeIfPresent(Set<Int>.self, forKey: .doneActions) ?? []
        hasResult = try c.decodeIfPresent(Bool.self, forKey: .hasResult) ?? false
        titleIsCustom = try c.decodeIfPresent(Bool.self, forKey: .titleIsCustom) ?? false
    }
}

extension ProcessingOptions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? []
        terms = try c.decodeIfPresent(String.self, forKey: .terms) ?? ""
        speakers = try c.decodeIfPresent(Bool.self, forKey: .speakers) ?? true
        correct = try c.decodeIfPresent(Bool.self, forKey: .correct) ?? true
        summary = try c.decodeIfPresent(Bool.self, forKey: .summary) ?? true
        summaryLanguage = try c.decodeIfPresent(String.self, forKey: .summaryLanguage) ?? "auto"
    }
}

/// Languages offered in the pickers; names come from the system, in the user's language.
enum SpokenLanguages {
    static let codes = ["fr", "en", "es", "de", "it", "pt", "nl", "pl", "ro", "sv", "da", "nb", "fi", "cs",
                        "el", "tr", "ru", "uk", "ar", "he", "hi", "ja", "ko", "zh"]
}
