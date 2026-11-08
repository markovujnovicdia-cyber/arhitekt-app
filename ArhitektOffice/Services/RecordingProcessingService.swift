import Foundation
import SwiftData
import Combine

@MainActor final class RecordingProcessingService: ObservableObject {
    @Published private(set) var progress = 0.0
    @Published private(set) var statusMessage = ""
    @Published private(set) var isProcessing = false
    @Published var errorMessage: String?

    /// Audio and inference remain on device. Checkpoints are independent from
    /// old cloud segment states and from immutable published transcript revisions.
    func transcribe(recording: RecordingSession, context: ModelContext, force: Bool = false) async {
        guard !isProcessing else { return }
        isProcessing = true; errorMessage = nil; progress = 0
        defer { isProcessing = false }
        do {
            guard !["recording", "paused", "preparing", "interrupted"].contains(recording.stateRaw),
                  !(LongRecordingService.shared.currentSession?.id == recording.id &&
                    [.recording, .paused, .preparing].contains(LongRecordingService.shared.state)) else {
                throw AIError.invalidResponse("Prvo završite snimanje prije lokalne obrade.")
            }
            guard let masterPath = recording.masterRelativePath else { throw AIError.noAudio }
            let fingerprint = try LocalInferenceCoordinator.shared.selectedWhisperFingerprint
            let modelKind = LocalModelStore.shared.selectedWhisperKind
            let url = try RecordingFileStore.shared.url(for: masterPath)
            statusMessage = "Priprema lokalnih PCM dijelova snimke…"
            let checkpointStore = LocalTranscriptionCheckpointStore()
            var saved: LocalTranscriptionCheckpoint?
            do { saved = try checkpointStore.load(recordingID: recording.id) }
            catch {
                // Preserve the unreadable journal for diagnosis; start a new one.
                try checkpointStore.archiveExisting(recordingID: recording.id)
            }
            let recordingID = recording.id
            let candidate = force ? nil : saved
            // Reading and silence scanning use a worker, not the SwiftUI thread.
            // A matching journal reuses its validated plan without rescanning audio.
            let planning = Task.detached(priority: .userInitiated) {
                let reader = try LocalAudioReader(url: url)
                let plan: [LocalAudioReader.Window]
                if let candidate, candidate.matches(recordingID: recordingID, modelFingerprint: fingerprint, source: reader.fingerprint) {
                    plan = candidate.windows.map(\.window)
                } else {
                    plan = try reader.planWindows()
                }
                return (reader.fingerprint, plan)
            }
            let (source, plan) = try await withTaskCancellationHandler {
                try await planning.value
            } onCancel: { planning.cancel() }
            let canResume = !force && (saved?.matches(recordingID: recording.id, modelFingerprint: fingerprint, source: source) ?? false)
            var checkpoint: LocalTranscriptionCheckpoint
            if canResume, let saved {
                checkpoint = saved
            } else {
                if saved != nil { try checkpointStore.archiveExisting(recordingID: recording.id) }
                checkpoint = LocalTranscriptionCheckpoint(recordingID: recording.id, modelFingerprint: fingerprint,
                    source: source, windows: plan.map { .init(window: $0) })
                try checkpointStore.save(checkpoint)
            }
            let count = checkpoint.windows.count
            guard count > 0 else { throw AIError.noAudio }
            for index in checkpoint.windows.indices {
                try Task.checkCancellation()
                guard try LocalInferenceCoordinator.shared.selectedWhisperFingerprint == fingerprint,
                      LocalModelStore.shared.selectedWhisperKind == modelKind else {
                    throw AIError.invalidResponse("Odabrani Whisper model je promijenjen. Prethodni rezultati su sačuvani; ponovno pokrenite obradu odabranim modelom.")
                }
                statusMessage = "Lokalna transkripcija dijela \(index + 1) od \(count)…"
                if !checkpoint.windows[index].completed {
                    let window = checkpoint.windows[index].window
                    let reading = Task.detached(priority: .userInitiated) {
                        let reader = try LocalAudioReader(url: url)
                        guard reader.fingerprint == source else {
                            throw AIError.invalidResponse("Audio datoteka se promijenila tijekom obrade. Izvor i raniji transkripti ostaju sačuvani.")
                        }
                        return try reader.samples(for: window)
                    }
                    let samples = try await withTaskCancellationHandler {
                        try await reading.value
                    } onCancel: { reading.cancel() }
                    let preceding = checkpoint.windows.prefix(index).filter(\.completed).map(\.text).joined(separator: " ")
                    // Prompt is short prior context, never an instruction or a source
                    // to append. The entire meeting is processed without truncation.
                    let prompt = preceding.split(whereSeparator: \.isWhitespace).suffix(100).joined(separator: " ")
                    let result = try await LocalInferenceCoordinator.shared.transcribe(samples: samples, prompt: prompt, progress: { [weak self] value in
                        Task { @MainActor [weak self] in
                            self?.progress = (Double(index) + min(1, max(0, value))) / Double(count)
                        }
                    })
                    let text = try LocalAudioReader.retainedText(
                        segments: result.segments.map { (start: $0.start, end: $0.end, text: $0.text) },
                        fallback: result.text, window: window)
                    checkpoint.windows[index].text = text
                    checkpoint.windows[index].completed = true
                    checkpoint.updatedAt = Date()
                    // Durable first. If the DB save fails, the next run restores it
                    // from this journal without rerunning successful inference.
                    try checkpointStore.save(checkpoint)
                }
                let completed = checkpoint.windows[index]
                let segment: AudioSegment
                if let existing = recording.segments.first(where: { $0.index == index }) { segment = existing }
                else {
                    segment = AudioSegment(index: index, relativePath: masterPath, duration: completed.window.ownedDuration, session: recording)
                    context.insert(segment)
                }
                segment.relativePath = masterPath
                segment.duration = completed.window.ownedDuration
                segment.transcriptText = completed.text
                segment.stateRaw = "local:\(fingerprint):completed"
                segment.lastError = nil
                try context.save()
                progress = Double(index + 1) / Double(count)
            }
            let complete = checkpoint.windows.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard !complete.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIError.invalidResponse("U snimci nije prepoznat govor. Snimka je sačuvana; preslušajte je, odaberite veći model ili ručno unesite transkript.")
            }
            // Resume is idempotent; force reprocessing can publish a new revision,
            // while old cloud/manual/local revisions always remain available.
            let provider = "whisper-\(modelKind.rawValue)-\(fingerprint)"
            if force || !recording.transcripts.contains(where: { $0.provider == provider && $0.text == complete }) {
                _ = try MemoryStore.appendTranscript(text: complete, to: recording, provider: provider, context: context)
            }
            recording.duration = Double(source.frameCount) / source.sampleRate
            recording.lastError = nil
            try context.save()
            statusMessage = "Cjelovit lokalni transkript je spremljen. Provjerite rubove dijelova; nesigurna ponavljanja nisu automatski izbrisana."
        } catch {
            let detail = error is CancellationError ? "Lokalna obrada je prekinuta na vaš zahtjev. Možete je nastaviti kasnije." : error.localizedDescription
            errorMessage = detail
            recording.lastError = detail
            try? context.save()
            statusMessage = "Lokalna obrada je pauzirana. Audio, raniji transkripti i uspješni dijelovi su sačuvani; obradu možete nastaviti."
        }
    }

    func analyze(transcript: TranscriptVersion, projects: [Project], context: [AIContextRecord], modelContext: ModelContext) async -> AnalysisResponse? {
        guard !isProcessing else { return nil }
        isProcessing = true; errorMessage = nil; progress = 0
        defer { isProcessing = false }
        do {
            statusMessage = "Lokalna semantička analiza svih dijelova transkripta…"
            let records = context.filter { $0.id != transcript.id }
            let result = try await LocalAIClient().analyze(transcript: transcript, projects: projects, context: records, progress: { [weak self] value in self?.progress = value })
            let encoded = try JSONEncoder().encode(result)
            let previousJSON = transcript.analysisJSON
            let previousSummary = transcript.analysisSummary
            transcript.analysisJSON = String(data: encoded, encoding: .utf8)
            transcript.analysisSummary = result.summary
            do { try modelContext.save() }
            catch {
                transcript.analysisJSON = previousJSON
                transcript.analysisSummary = previousSummary
                throw error
            }
            progress = 1
            statusMessage = "Lokalni prijedlozi su spremljeni za pregled. Strukturirani podaci još nisu promijenjeni."
            return result
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Lokalna analiza nije dovršena. Izvor i prethodni prijedlozi ostaju sačuvani; obrađeni dijelovi mogu se nastaviti."
            return nil
        }
    }
}
