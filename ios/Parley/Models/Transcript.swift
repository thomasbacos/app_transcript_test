import Foundation

struct Turn: Codable, Hashable {
    var spk: String
    var start: Double
    var end: Double
    var text: String
}

struct SummarySection: Codable, Hashable {
    var head: String
    var bullets: [String]
}

struct ActionItem: Codable, Hashable {
    var task: String
    var owner: String
    var due: String
}

struct Summary: Codable, Hashable {
    var kind: String?
    var title: String
    var subtitle: String
    var sections: [SummarySection]
    var actions: [ActionItem]?
}

struct Correction: Codable, Hashable {
    var from: String
    var to: String
    var why: String
}

/// What the server returns for a finished job (see server/app/pipeline/process.py).
/// No automatic snake_case conversion here: it would also rewrite the speaker labels used as keys.
struct TranscriptResult: Codable {
    var duration: Double
    var language: String?
    var languages: [String]?
    var title: String?
    var text: String
    var rawText: String?
    var turns: [Turn]
    var names: [String: String]
    var summary: Summary?
    var corrections: [Correction]
    var warnings: [String]
    var docs: [String]?
    var wordCount: Int?

    enum CodingKeys: String, CodingKey {
        case duration, language, languages, title, text, turns, names, summary, corrections, warnings, docs
        case rawText = "raw_text"
        case wordCount = "word_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        language = try c.decodeIfPresent(String.self, forKey: .language)
        languages = try c.decodeIfPresent([String].self, forKey: .languages)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText)
        turns = try c.decodeIfPresent([Turn].self, forKey: .turns) ?? []
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        summary = try c.decodeIfPresent(Summary.self, forKey: .summary)
        corrections = try c.decodeIfPresent([Correction].self, forKey: .corrections) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        docs = try c.decodeIfPresent([String].self, forKey: .docs)
        wordCount = try c.decodeIfPresent(Int.self, forKey: .wordCount)
    }

    /// Speaker labels in order of first appearance.
    var speakers: [String] {
        var seen = Set<String>()
        return turns.compactMap { seen.insert($0.spk).inserted ? $0.spk : nil }
    }

    func displayName(_ spk: String, overrides: [String: String]) -> String {
        if let n = overrides[spk], !n.isEmpty { return n }
        if let n = names[spk], !n.isEmpty { return n }
        return tr("Speaker %@", spk)
    }

    func speakerIndex(_ spk: String) -> Int {
        speakers.firstIndex(of: spk) ?? 0
    }
}
