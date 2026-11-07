import CryptoKit
import Foundation
import SwiftData

struct ConfirmationResult {
    var insertedCount: Int
    var skippedCount: Int
    var entryIDs: [UUID]
}

enum MemoryStoreError: LocalizedError {
    case invalidTranscript, invalidEvidence, missingProject, invalidDate, invalidRelatedEntry, unsavedChanges
    var errorDescription: String? {
        switch self {
        case .invalidTranscript: "Transkript je prazan, predugačak ili nije spremljen."
        case .invalidEvidence: "Prijedlog nema valjanu referencu na izvorni transkript. Provjerite tekst i označeni izvor."
        case .missingProject: "Za svaki odabrani prijedlog odaberite postojeći projekt."
        case .invalidDate: "Rok mora biti valjan datum u obliku GGGG-MM-DD ili ostati prazan."
        case .invalidRelatedEntry: "Povezani zapis ne postoji ili pripada drugom projektu."
        case .unsavedChanges: "Prije potvrde spremite ostale promjene."
        }
    }
}

@MainActor enum MemoryStore {
    /// Always append a correction as a new revision. Prior versions and their
    /// exact UTF-16 evidence offsets are never rewritten.
    @discardableResult
    static func appendTranscript(text: String, to recording: RecordingSession, provider: String = "ručno",
                                 context: ModelContext) throws -> TranscriptVersion {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 5_000_000 else { throw MemoryStoreError.invalidTranscript }
        if let previous = recording.latestTranscript, previous.text == text, previous.provider == provider {
            return previous
        }
        let previous = recording.latestTranscript
        let next = (recording.transcripts.map(\.revision).max() ?? 0) + 1
        let version = TranscriptVersion(text: text, recording: recording, provider: provider,
                                        revision: next, supersedesID: previous?.id)
        context.insert(version)
        recording.updatedAt = Date()
        do { try context.save() }
        catch { context.rollback(); throw error }
        return version
    }

    /// The caller passes only proposals explicitly selected and reviewed by the
    /// user. This method performs no cloud work and never accepts a suggestion
    /// merely because an AI response was received.
    @discardableResult
    static func confirm(proposals: [MemoryProposal], transcript: TranscriptVersion,
                        context: ModelContext) throws -> ConfirmationResult {
        guard !context.hasChanges else { throw MemoryStoreError.unsavedChanges }
        let transcripts = try context.fetch(FetchDescriptor<TranscriptVersion>())
        guard transcripts.contains(where: { $0.id == transcript.id && $0.text == transcript.text }) else {
            throw MemoryStoreError.invalidTranscript
        }
        let projects = try context.fetch(FetchDescriptor<Project>())
        let prior = try context.fetch(FetchDescriptor<MemoryEntry>())
        var evidenceKeys = Set(prior.map(\.evidenceKey))
        var prepared: [(MemoryProposal, Project, String, Date?)] = []
        for proposal in proposals {
            guard let projectID = proposal.projectID, let project = projects.first(where: { $0.id == projectID }) else {
                throw MemoryStoreError.missingProject
            }
            try validateEvidence(proposal.source, in: transcript)
            guard !proposal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  proposal.title.utf8.count <= 2_000, proposal.details.utf8.count <= 100_000 else {
                throw MemoryStoreError.invalidEvidence
            }
            if let related = proposal.relatedEntryID {
                guard prior.contains(where: { $0.id == related && $0.project?.id == projectID }) else {
                    throw MemoryStoreError.invalidRelatedEntry
                }
            }
            let due = try proposal.dueDate.flatMap { value -> Date? in
                guard !value.isEmpty else { return nil }
                return try parseDate(value)
            }
            prepared.append((proposal, project, evidenceKey(for: proposal, transcript: transcript), due))
        }

        var inserted = 0
        var skipped = 0
        var ids: [UUID] = []
        do {
            for (proposal, project, key, due) in prepared {
                guard evidenceKeys.insert(key).inserted else { skipped += 1; continue }
                let entry = MemoryEntry(kind: proposal.kind, title: proposal.title, details: proposal.details,
                                        certainty: proposal.certainty, project: project, transcript: transcript,
                                        startUTF16: proposal.source.startUTF16, endUTF16: proposal.source.endUTF16,
                                        quote: proposal.source.quote, evidenceKey: key)
                entry.responsible = proposal.responsible?.trimmingCharacters(in: .whitespacesAndNewlines)
                entry.dueDate = due
                entry.relatedEntryID = proposal.relatedEntryID
                context.insert(entry)
                // Keep the existing central task/problem/note workflows usable.
                // Their links always lead back to the richer provenance record.
                let details = "\(proposal.certainty.label)\n\(proposal.details)"
                switch proposal.kind {
                case .task:
                    let task = ProjectTask(title: proposal.title, details: details, dueDate: due, project: project)
                    task.responsible = entry.responsible
                    task.sourceMemoryID = entry.id
                    context.insert(task)
                case .issue:
                    let issue = ProjectIssue(title: proposal.title, details: details, project: project)
                    issue.sourceMemoryID = entry.id
                    context.insert(issue)
                case .note:
                    let note = ProjectNote(text: "\(proposal.title)\n\(proposal.details)",
                                           sourceTranscript: transcript.text, project: project)
                    note.sourceMemoryID = entry.id
                    context.insert(note)
                default: break
                }
                project.touch()
                ids.append(entry.id)
                inserted += 1
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return ConfirmationResult(insertedCount: inserted, skippedCount: skipped, entryIDs: ids)
    }

    static func validateEvidence(_ source: EvidenceReference, in transcript: TranscriptVersion) throws {
        let count = transcript.text.utf16.count
        guard source.transcriptID == transcript.id, source.startUTF16 >= 0,
              source.endUTF16 > source.startUTF16, source.endUTF16 <= count,
              let range = Range(NSRange(location: source.startUTF16, length: source.endUTF16 - source.startUTF16),
                                in: transcript.text),
              transcript.text[range].utf16.elementsEqual(source.quote.utf16) else {
            throw MemoryStoreError.invalidEvidence
        }
    }

    static func evidenceKey(for proposal: MemoryProposal, transcript: TranscriptVersion) -> String {
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "hr_HR"))
                .lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let parts = [proposal.projectID?.uuidString ?? "", transcript.recording?.id.uuidString ?? transcript.id.uuidString,
                     proposal.kind.rawValue, normalized(proposal.source.quote), normalized(proposal.title)]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func parseDate(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Europe/Zagreb")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw MemoryStoreError.invalidDate
        }
        return date
    }
}
