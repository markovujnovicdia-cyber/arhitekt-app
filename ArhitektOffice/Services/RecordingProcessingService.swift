import Foundation
import SwiftData
import Combine

@MainActor final class RecordingProcessingService: ObservableObject {
    @Published private(set) var progress = 0.0
    @Published private(set) var statusMessage = ""
    @Published private(set) var isProcessing = false
    @Published var errorMessage: String?

    /// Caller presents the cloud consent first. Each successful part is committed
    /// immediately; errors never remove the master, chunks or previous revisions.
    func transcribe(recording: RecordingSession, context: ModelContext, force: Bool = false) async {
        guard !isProcessing else { return }
        isProcessing = true; errorMessage = nil; progress = 0
        defer { isProcessing = false }
        do {
            guard !["recording", "paused", "preparing", "interrupted"].contains(recording.stateRaw) else {
                throw AIError.invalidResponse("Prvo završite snimanje prije cloud obrade.")
            }
            statusMessage = "Priprema dijelova snimke…"
            let recorder = LongRecordingService.shared
            let segments = try await recorder.prepareSegments(for: recording, context: context)
            guard !segments.isEmpty else { throw AIError.noAudio }
            let client = CloudAIClient()
            if force {
                for segment in segments { segment.stateRaw = "pending" }
                try context.save()
            }
            for (index, segment) in segments.enumerated() {
                try Task.checkCancellation()
                statusMessage = "Transkripcija dijela \(index + 1) od \(segments.count)…"
                if segment.stateRaw != "completed" {
                    do {
                        let url = try RecordingFileStore.shared.url(for: segment.relativePath)
                        segment.transcriptText = try await client.transcribe(fileURL: url)
                        segment.stateRaw = "completed"; segment.lastError = nil
                        try context.save()
                    } catch {
                        segment.lastError = "Obrada nije uspjela. Dio je sačuvan za ponovni pokušaj."
                        try? context.save()
                        throw error
                    }
                }
                progress = Double(index + 1) / Double(segments.count)
            }
            let complete = segments.sorted { $0.index < $1.index }.map(\.transcriptText).joined(separator: "\n\n")
            guard !complete.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIError.invalidResponse("Prepoznavanje nije vratilo tekst. Snimka je sačuvana; pokušajte ponovnu obradu.")
            }
            _ = try MemoryStore.appendTranscript(text: complete, to: recording, provider: "cloud", context: context)
            recording.lastError = nil
            try context.save()
            statusMessage = "Cjelovit transkript je spremljen. Pregledajte ga prije analize."
        } catch {
            errorMessage = error.localizedDescription
            recording.lastError = error.localizedDescription
            try? context.save()
            statusMessage = "Obrada je zaustavljena; audio i uspješno obrađeni dijelovi ostaju sačuvani."
        }
    }

    func analyze(transcript: TranscriptVersion, projects: [Project], context: [AIContextRecord], modelContext: ModelContext) async -> AnalysisResponse? {
        guard !isProcessing else { return nil }
        isProcessing = true; errorMessage = nil; progress = 0
        defer { isProcessing = false }
        do {
            statusMessage = "Semantička analiza svih dijelova transkripta…"
            let records = context.filter { $0.id != transcript.id }
            let result = try await CloudAIClient().analyze(transcript: transcript, projects: projects, context: records, progress: { [weak self] value in self?.progress = value })
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
            statusMessage = "Prijedlozi su spremljeni za pregled. Strukturirani podaci još nisu promijenjeni."
            return result
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Analiza nije dovršena. Izvorni transkript i prethodni prijedlozi ostaju sačuvani."
            return nil
        }
    }
}
