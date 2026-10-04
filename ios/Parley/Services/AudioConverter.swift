import AVFoundation

/// Audio files: recording (PCM, crash-safe) -> compressed AAC for storage and upload; imports of any
/// audio or video file -> AAC audio only.
enum AudioConverter {
    enum Failure: LocalizedError {
        case noAudio
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: return tr("This file contains no audio.")
            case .exportFailed(let m): return tr("Could not read this file (%@).", m)
            }
        }
    }

    /// PCM/any AVAudioFile-readable file -> AAC .m4a, same sample rate, mono. Returns the duration (s).
    static func toAAC(source: URL, destination: URL) async throws -> TimeInterval {
        try await Task.detached(priority: .userInitiated) {
            var lastError: Error = Failure.noAudio
            // The AAC encoder's accepted bit rates depend on the sample rate: try from best to safest.
            // The speaker model needs >= 64 kbps at 24 kHz to keep non-English speech untranslated.
            for bitRate in [96_000, 80_000, 64_000, 48_000] {
                do {
                    return try encode(source: source, destination: destination, bitRate: bitRate)
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }.value
    }

    private static func encode(source: URL, destination: URL, bitRate: Int) throws -> TimeInterval {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard input.length > 0, format.sampleRate > 0 else { throw Failure.noAudio }
        try? FileManager.default.removeItem(at: destination)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
        do {
            let output = try AVAudioFile(forWriting: destination, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
                throw Failure.noAudio
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        } // `output` is released here, which finalizes the file
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw Failure.exportFailed("empty output") }
        return Double(input.length) / format.sampleRate
    }

    /// Imported audio or video -> AAC audio in `destination`. Returns the duration.
    static func importMedia(from source: URL, to destination: URL) async throws -> TimeInterval {
        if let d = try? await toAAC(source: source, destination: destination), d > 0 {
            return d
        }
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Failure.noAudio }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.exportFailed("preset")
        }
        try? FileManager.default.removeItem(at: destination)
        export.outputURL = destination
        export.outputFileType = .m4a
        let box = ExportBox(export)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously { done.resume() }
        }
        guard export.status == .completed else {
            throw Failure.exportFailed(export.error?.localizedDescription ?? "export")
        }
        return try await duration(of: destination)
    }

    static func duration(of url: URL) async throws -> TimeInterval {
        let d = try await AVURLAsset(url: url).load(.duration)
        return d.seconds.isFinite ? d.seconds : 0
    }
}

private final class ExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ s: AVAssetExportSession) { session = s }
}

/// A recording interrupted by a crash or a dead battery leaves a CAF file whose header was never
/// finalized. Its samples are intact: everything after the `data` chunk header is raw PCM. This
/// rebuilds a valid WAV from it, streaming from disk (a 6-hour recording is about 1 GB).
enum CAFRepair {
    enum Failure: Error { case notCAF, unsupported }

    static func repair(_ caf: URL) throws -> URL {
        let input = try FileHandle(forReadingFrom: caf)
        defer { try? input.close() }
        let fileSize = Int(try input.seekToEnd())
        try input.seek(toOffset: 0)
        // The header chunks (desc, kuki, free...) all sit before the audio data, in the first kilobytes.
        let data = try input.read(upToCount: min(fileSize, 1 << 20)) ?? Data()
        guard data.count > 8, data.prefix(4) == Data("caff".utf8) else { throw Failure.notCAF }
        var pos = 8
        var sampleRate = 24_000.0
        var channels: UInt32 = 1
        var bits: UInt32 = 16
        var bigEndian = false
        var isFloat = false
        var payload: Range<Int>?
        while pos + 12 <= data.count {
            let type = String(decoding: data[(data.startIndex + pos)..<(data.startIndex + pos + 4)], as: UTF8.self)
            let size = Int64(bitPattern: be(data, pos + 4, as: UInt64.self))
            let body = pos + 12
            if type == "desc", body + 32 <= data.count {
                sampleRate = Double(bitPattern: be(data, body, as: UInt64.self))
                let flags = be(data, body + 12, as: UInt32.self)
                isFloat = flags & 1 != 0
                bigEndian = flags & 2 != 0
                channels = be(data, body + 24, as: UInt32.self)
                bits = be(data, body + 28, as: UInt32.self)
            }
            if type == "data" {
                let start = body + 4                     // 4-byte edit count
                var end = fileSize                       // size -1 / 0: the data runs to the end of the file
                if size > 4, body + Int(size) <= fileSize { end = body + Int(size) }
                payload = start..<end
                break
            }
            guard size >= 0, body + Int(size) <= data.count else { break }
            pos = body + Int(size)
        }
        guard let payload, !isFloat, bits == 16, channels >= 1, sampleRate > 0 else { throw Failure.unsupported }
        let frameBytes = Int(channels) * 2
        let length = (payload.count / frameBytes) * frameBytes

        var header = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); put(UInt32(clamping: 36 + length))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(channels))
        put(UInt32(sampleRate)); put(UInt32(sampleRate) * UInt32(frameBytes)); put(UInt16(frameBytes)); put(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); put(UInt32(clamping: length))

        let out = caf.deletingPathExtension().appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: out)
        guard FileManager.default.createFile(atPath: out.path, contents: header) else { throw Failure.unsupported }
        let output = try FileHandle(forWritingTo: out)
        defer { try? output.close() }
        try output.seekToEnd()
        try input.seek(toOffset: UInt64(payload.lowerBound))
        var remaining = length
        while remaining > 0 {
            guard var chunk = try input.read(upToCount: min(remaining, 4 << 20)), !chunk.isEmpty else { break }
            if chunk.count % 2 == 1 { chunk.removeLast() }
            if bigEndian {
                chunk.withUnsafeMutableBytes { raw in
                    let p = raw.bindMemory(to: UInt16.self)
                    for i in 0..<p.count { p[i] = p[i].byteSwapped }
                }
            }
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
        }
        return out
    }

    private static func be<T: FixedWidthInteger>(_ d: Data, _ offset: Int, as: T.Type) -> T {
        var v: T = 0
        for i in 0..<MemoryLayout<T>.size {
            v = (v << 8) | T(d[d.startIndex + offset + i])
        }
        return v
    }
}
