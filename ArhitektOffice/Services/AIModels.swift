import Foundation

struct EvidenceReference: Codable, Hashable {
    var transcriptID: UUID
    var startUTF16: Int
    var endUTF16: Int
    var quote: String

    func validate(in transcript: TranscriptVersion) throws {
        let source = transcript.text as NSString
        guard transcriptID == transcript.id, startUTF16 >= 0, endUTF16 > startUTF16,
              endUTF16 <= source.length,
              let range = Range(NSRange(location: startUTF16, length: endUTF16 - startUTF16), in: transcript.text),
              transcript.text[range].utf16.elementsEqual(quote.utf16) else {
            throw AIError.invalidResponse("Izdvojena informacija nema valjanu referencu na izvorni transkript.")
        }
    }
}

struct MemoryProposal: Codable, Identifiable {
    var id: UUID
    var projectID: UUID?
    var kind: MemoryKind
    var certainty: MemoryCertainty
    var title: String
    var details: String
    var responsible: String?
    var dueDate: String?
    var source: EvidenceReference
    var relatedEntryID: UUID?
}

struct AnalysisResponse: Codable {
    var summary: String
    var proposals: [MemoryProposal]
}

struct AskResponse: Codable {
    var answer: String
    var sourceIDs: [UUID]
    var insufficientData: Bool
}

struct AIContextRecord: Codable, Identifiable, Hashable, Sendable {
    var recordType: String = "record"
    var sourceStartUTF16: Int? = nil
    var sourceEndUTF16: Int? = nil
    var id: UUID
    var projectID: UUID?
    var date: Date
    var title: String
    var text: String
}

struct AIProjectRecord: Codable {
    var id: UUID
    var name: String
    var number: String
}

enum AIError: LocalizedError {
    case notConfigured, invalidResponse(String), requestFailed(Int), tooLarge, noAudio
    var errorDescription: String? {
        switch self {
        case .notConfigured: "U Postavkama uvezite lokalne Whisper i Qwen modele. Obrada ne koristi internet."
        case .invalidResponse(let message): message
        case .requestFailed(let code): "Lokalna obrada nije dovršena (oznaka \(code)). Izvorni podaci su sačuvani. Pokušajte ponovno kasnije."
        case .tooLarge: "Dio snimke ili zahtjev prelazi dopuštenu veličinu. Izvorna snimka ostaje sačuvana."
        case .noAudio: "Za ovu snimku nema dostupnog zvučnog zapisa. Transkript i memorija ostaju dostupni."
        }
    }
}
