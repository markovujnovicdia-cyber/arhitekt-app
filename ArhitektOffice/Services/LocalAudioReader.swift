import AVFoundation
import Foundation

/// Bounded-memory PCM access for native Whisper. No audio is uploaded and no
/// entire meeting is loaded into RAM. Every descriptor refers to the master CAF.
final class LocalAudioReader {
    static let whisperSampleRate = 16_000.0
    let url: URL
    private let file: AVAudioFile
    let sourceFrameCount: Int64
    let sourceSampleRate: Double
    let fingerprint: SourceFingerprint

    struct SourceFingerprint: Codable, Equatable, Sendable {
        var frameCount: Int64
        var sampleRate: Double
        var byteCount: Int64
        var modifiedAt: Date
    }

    struct Window: Codable, Equatable, Sendable {
        var index: Int
        var sourceStartFrame: Int64
        var ownedStartFrame: Int64
        var endFrame: Int64
        var sourceSampleRate: Double
        var duration: Double { Double(endFrame - sourceStartFrame) / sourceSampleRate }
        var ownedDuration: Double { Double(endFrame - ownedStartFrame) / sourceSampleRate }
        var leftContextDuration: Double { Double(ownedStartFrame - sourceStartFrame) / sourceSampleRate }
    }

    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(forReading: url)
        sourceFrameCount = file.length
        sourceSampleRate = file.processingFormat.sampleRate
        guard sourceFrameCount > 0, sourceSampleRate.isFinite, sourceSampleRate > 0,
              file.processingFormat.channelCount > 0 else { throw ReaderError.invalidAudio }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        fingerprint = SourceFingerprint(frameCount: sourceFrameCount, sampleRate: sourceSampleRate,
                                        byteCount: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .distantPast)
    }

    /// Owned intervals cover the master exactly once. One second of left context
    /// protects words at a seam; boundaries prefer quiet frames near 27 seconds.
    func planWindows() throws -> [Window] {
        var ownedStart: Int64 = 0
        var windows: [Window] = []
        while ownedStart < sourceFrameCount {
            try Task.checkCancellation()
            let end: Int64
            if sourceFrameCount - ownedStart <= Int64(29 * sourceSampleRate) {
                end = sourceFrameCount
            } else {
                end = try quietBoundary(after: ownedStart)
            }
            let left = windows.isEmpty ? 0 : min(ownedStart, Int64(sourceSampleRate))
            windows.append(Window(index: windows.count, sourceStartFrame: ownedStart - left,
                                  ownedStartFrame: ownedStart, endFrame: end, sourceSampleRate: sourceSampleRate))
            ownedStart = end
        }
        try Self.validate(windows, source: fingerprint)
        return windows
    }

    func samples(for window: Window) throws -> [Float] {
        guard window.sourceSampleRate == sourceSampleRate,
              window.sourceStartFrame >= 0, window.endFrame <= sourceFrameCount,
              window.endFrame > window.sourceStartFrame, window.duration <= 30.001 else { throw ReaderError.invalidWindow }
        return try readSamples(startFrame: window.sourceStartFrame, frameCount: window.endFrame - window.sourceStartFrame)
    }

    static func validate(_ windows: [Window], source: SourceFingerprint) throws {
        guard !windows.isEmpty, source.sampleRate.isFinite, source.sampleRate > 0, source.frameCount > 0 else {
            throw ReaderError.invalidWindow
        }
        var nextOwned: Int64 = 0
        for (index, window) in windows.enumerated() {
            guard window.index == index, window.sourceSampleRate == source.sampleRate,
                  window.ownedStartFrame == nextOwned, window.sourceStartFrame >= 0,
                  window.sourceStartFrame <= window.ownedStartFrame,
                  window.endFrame > window.ownedStartFrame, window.endFrame <= source.frameCount,
                  window.duration <= 30.001, window.leftContextDuration <= 1.001 else { throw ReaderError.invalidWindow }
            nextOwned = window.endFrame
        }
        guard nextOwned == source.frameCount else { throw ReaderError.invalidWindow }
    }

    /// Called only with native segments whose timestamps are relative to the PCM
    /// window. Discard a segment only when it lies entirely in already-owned audio.
    /// Keep straddling segments and real repetitions; lexical dedup is unsafe.
    static func retainedText(segments: [(start: Double, end: Double, text: String)], fallback: String, window: Window) throws -> String {
        guard segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= window.duration + 1 }) else {
            throw ReaderError.invalidTimestamps
        }
        if segments.isEmpty { return fallback.trimmingCharacters(in: .whitespacesAndNewlines) }
        return segments.filter { $0.end > window.leftContextDuration }
            .map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func quietBoundary(after start: Int64) throws -> Int64 {
        let searchStart = start + Int64(24 * sourceSampleRate)
        let searchEnd = min(sourceFrameCount, start + Int64(29 * sourceSampleRate))
        let samples = try readSamples(startFrame: searchStart, frameCount: searchEnd - searchStart)
        let hop = 320 // 20 ms at 16 kHz
        guard samples.count >= hop else { return searchEnd }
        var bestScore = Double.infinity
        var bestIndex = min(samples.count - 1, Int(3 * Self.whisperSampleRate))
        for offset in stride(from: 0, through: samples.count - hop, by: hop) {
            var sum = 0.0
            for sample in samples[offset..<(offset + hop)] { sum += Double(sample) * Double(sample) }
            let rms = sqrt(sum / Double(hop))
            let seconds = Double(offset) / Self.whisperSampleRate
            // Prefer a low-energy boundary near 27s; ties choose nearest target.
            let score = rms + abs(seconds - 3) * 0.0001
            if score < bestScore { bestScore = score; bestIndex = offset + hop / 2 }
        }
        let delta = Int64(Double(bestIndex) / Self.whisperSampleRate * sourceSampleRate)
        return min(searchEnd, max(start + 1, searchStart + delta))
    }

    private func readSamples(startFrame: Int64, frameCount: Int64) throws -> [Float] {
        try Task.checkCancellation()
        guard frameCount > 0, frameCount <= Int64(sourceSampleRate * 30.01),
              frameCount <= Int64(UInt32.max), startFrame >= 0, startFrame + frameCount <= sourceFrameCount else {
            throw ReaderError.invalidWindow
        }
        file.framePosition = startFrame
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw ReaderError.conversionFailed
        }
        try file.read(into: input, frameCount: AVAudioFrameCount(frameCount))
        guard input.frameLength > 0 else { throw ReaderError.invalidAudio }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.whisperSampleRate, channels: 1, interleaved: false) else {
            throw ReaderError.conversionFailed
        }
        let buffer: AVAudioPCMBuffer
        if input.format == target {
            buffer = input
        } else {
            guard let converter = AVAudioConverter(from: input.format, to: target),
                  let output = AVAudioPCMBuffer(pcmFormat: target,
                      frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * Self.whisperSampleRate / sourceSampleRate)) + 64) else {
                throw ReaderError.conversionFailed
            }
            var provided = false
            var conversionError: NSError?
            let result = converter.convert(to: output, error: &conversionError) { _, status in
                if provided { status.pointee = .endOfStream; return nil }
                provided = true
                status.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            guard result != .error else { throw ReaderError.conversionFailed }
            buffer = output
        }
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { throw ReaderError.conversionFailed }
        let expected = Int(ceil(Double(input.frameLength) * Self.whisperSampleRate / sourceSampleRate))
        let count = min(Int(buffer.frameLength), expected)
        let samples = Array(UnsafeBufferPointer(start: channel, count: count))
        guard samples.allSatisfy(\.isFinite) else { throw ReaderError.invalidAudio }
        return samples
    }

    enum ReaderError: LocalizedError {
        case invalidAudio, invalidWindow, conversionFailed, invalidTimestamps
        var errorDescription: String? {
            switch self {
            case .invalidAudio: "Audio nije čitljiv. Izvorna snimka ostaje sačuvana."
            case .invalidWindow: "Lokalni dijelovi snimke nisu valjani. Pokrenite ponovnu obradu."
            case .conversionFailed: "Pretvorba zvuka u lokalni Whisper format nije uspjela."
            case .invalidTimestamps: "Whisper je vratio nevaljane vremenske oznake. Audio i prethodni rezultati ostaju sačuvani."
            }
        }
    }
}

/// Separate from source recordings and immutable published transcript revisions.
/// A completed window is durable before the next native inference starts.
struct LocalTranscriptionCheckpoint: Codable, Sendable {
    var version = 1
    var recordingID: UUID
    var modelFingerprint: String
    var source: LocalAudioReader.SourceFingerprint
    var windows: [Result]
    var updatedAt = Date()

    struct Result: Codable, Sendable {
        var window: LocalAudioReader.Window
        var text = ""
        var completed = false
    }

    func matches(recordingID: UUID, modelFingerprint: String, source: LocalAudioReader.SourceFingerprint) -> Bool {
        self.recordingID == recordingID && self.modelFingerprint == modelFingerprint && self.source == source
    }

    func validate() throws {
        guard version == 1, !modelFingerprint.isEmpty else { throw LocalAudioReader.ReaderError.invalidWindow }
        try LocalAudioReader.validate(windows.map(\.window), source: source)
    }
}

struct LocalTranscriptionCheckpointStore {
    let files: RecordingFileStore
    init(files: RecordingFileStore = .shared) { self.files = files }

    func load(recordingID: UUID) throws -> LocalTranscriptionCheckpoint? {
        let url = try checkpointURL(recordingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(LocalTranscriptionCheckpoint.self, from: Data(contentsOf: url))
        guard value.recordingID == recordingID else { throw LocalAudioReader.ReaderError.invalidWindow }
        try value.validate()
        return value
    }

    func save(_ value: LocalTranscriptionCheckpoint) throws {
        try value.validate()
        let url = try checkpointURL(value.recordingID)
        try files.createProtectedDirectory(url.deletingLastPathComponent())
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func archiveExisting(recordingID: UUID) throws {
        let url = try checkpointURL(recordingID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = url.deletingLastPathComponent().appendingPathComponent("local-transcription-history-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: url, to: archive)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: archive.path)
    }

    private func checkpointURL(_ id: UUID) throws -> URL { try files.url(for: "\(id.uuidString)/local-transcription-v1.json") }
}
