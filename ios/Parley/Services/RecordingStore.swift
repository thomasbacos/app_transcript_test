import Foundation
import Observation

/// Recordings live in Application Support/Recordings/<id>/: meta.json, the audio, result.json and the
/// reference documents. Plain files: easy to back up, nothing to migrate.
@MainActor
@Observable
final class RecordingStore {
    private(set) var recordings: [Recording] = []
    @ObservationIgnored private var results: [UUID: TranscriptResult] = [:]
    @ObservationIgnored let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func audioURL(_ r: Recording) -> URL { folder(r.id).appendingPathComponent(r.audioFile) }
    func docsFolder(_ id: UUID) -> URL { folder(id).appendingPathComponent("docs", isDirectory: true) }
    private func metaURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("meta.json") }
    private func resultURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("result.json") }

    func load() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var out: [Recording] = []
        for d in dirs {
            if let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")),
               let r = try? JSONDecoder().decode(Recording.self, from: data) {
                out.append(r)
            }
        }
        recordings = out.sorted { $0.createdAt > $1.createdAt }
    }

    func recording(_ id: UUID) -> Recording? { recordings.first { $0.id == id } }
    func recording(jobID: String) -> Recording? { recordings.first { $0.jobID == jobID } }

    func save(_ r: Recording) {
        if let i = recordings.firstIndex(where: { $0.id == r.id }) {
            recordings[i] = r
        } else {
            recordings.append(r)
            recordings.sort { $0.createdAt > $1.createdAt }
        }
        persist(r)
    }

    func update(_ id: UUID, _ change: (inout Recording) -> Void) {
        guard var r = recording(id) else { return }
        change(&r)
        save(r)
    }

    private func persist(_ r: Recording) {
        try? FileManager.default.createDirectory(at: folder(r.id), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(r) {
            try? data.write(to: metaURL(r.id), options: .atomic)
        }
    }

    func delete(_ id: UUID) {
        recordings.removeAll { $0.id == id }
        results[id] = nil
        try? FileManager.default.removeItem(at: folder(id))
    }

    func deleteAll() {
        for r in recordings { try? FileManager.default.removeItem(at: folder(r.id)) }
        recordings = []
        results = [:]
    }

    // MARK: results

    func result(for id: UUID) -> TranscriptResult? {
        if let r = results[id] { return r }
        guard let data = try? Data(contentsOf: resultURL(id)),
              let r = try? JSONDecoder().decode(TranscriptResult.self, from: data) else { return nil }
        results[id] = r
        return r
    }

    @discardableResult
    func saveResult(_ data: Data, for id: UUID) throws -> TranscriptResult {
        let r = try JSONDecoder().decode(TranscriptResult.self, from: data)
        try data.write(to: resultURL(id), options: .atomic)
        results[id] = r
        return r
    }

    /// Text used by search: title + summary + transcript, loaded lazily.
    func searchableText(_ id: UUID) -> String {
        guard let r = result(for: id) else { return "" }
        return [r.summary?.title ?? "", r.text].joined(separator: "\n")
    }

    // MARK: documents

    func copyDocs(_ urls: [URL], to id: UUID) -> [URL] {
        let dir = docsFolder(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for u in urls {
            let access = u.startAccessingSecurityScopedResource()
            defer { if access { u.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(u.lastPathComponent)
            if dest.standardizedFileURL == u.standardizedFileURL {
                out.append(dest)
                continue
            }
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { out.append(dest) }
        }
        return out
    }

    func docs(for id: UUID) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: docsFolder(id), includingPropertiesForKeys: nil)) ?? []
    }

    var freeSpace: Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
