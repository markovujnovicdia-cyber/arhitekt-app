import Foundation

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never redirect private records or bearer credentials.
    }
}

@MainActor
final class CloudAIClient {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func transcribe(fileURL: URL) async throws -> String {
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw AIError.noAudio }
        guard size <= 20 * 1_024 * 1_024 else { throw AIError.tooLarge }
        let boundary = "Office-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"segment.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8)
        body.append(try Data(contentsOf: fileURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        struct Result: Decodable { let text: String }
        let result: Result = try await send(path: "transcribe", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalidResponse("Za ovaj dio nije prepoznat govor. Zvuk je sačuvan; preslušajte ga pa ponovite obradu ili ručno unesite cjelovit transkript.")
        }
        return result.text
    }

    func analyze(transcript: TranscriptVersion, projects: [Project], context: [AIContextRecord], progress: ((Double) -> Void)? = nil) async throws -> AnalysisResponse {
        struct Payload: Encodable {
            struct Transcript: Encodable { var id: UUID; var text: String }
            var transcript: Transcript
            var projects: [AIProjectRecord]
            var context: [AIContextRecord]
        }
        // Analyze every part in original order. Nothing is silently truncated.
        let nsText = transcript.text as NSString
        var offset = 0
        var summaries: [String] = []
        var proposals: [MemoryProposal] = []
        let allowedProjects = Set(projects.map(\.id))
        let allowedRelations = Set(context.filter { $0.recordType == "memory" }.map(\.id))
        while offset < nsText.length {
            try Task.checkCancellation()
            let desired = NSRange(location: offset, length: min(12_000, nsText.length - offset))
            let range = nsText.rangeOfComposedCharacterSequences(for: desired)
            let fragment = nsText.substring(with: range)
            var fragmentContext = context.filter { $0.id != transcript.id }
            if range.location > 0 {
                let priorRange = nsText.rangeOfComposedCharacterSequences(for: NSRange(location: max(0, range.location - 2_000), length: min(2_000, range.location)))
                fragmentContext.append(AIContextRecord(recordType: "transcript", id: transcript.id,
                    projectID: transcript.recording?.project?.id, date: transcript.createdAt,
                    title: "Prethodni dio iste snimke; samo kontekst, nije novi događaj",
                    text: nsText.substring(with: priorRange)))
            }
            let payload = Payload(transcript: .init(id: transcript.id, text: fragment),
                projects: projects.map { AIProjectRecord(id: $0.id, name: $0.name, number: $0.number) }, context: fragmentContext)
            let result: AnalysisResponse = try await sendJSON(path: "analyze", payload: payload)
            guard result.proposals.count <= 200 else { throw AIError.invalidResponse("Poslužitelj je vratio previše prijedloga.") }
            summaries.append(result.summary)
            for var proposal in result.proposals {
                guard proposal.source.startUTF16 >= 0,
                      proposal.source.endUTF16 > proposal.source.startUTF16,
                      proposal.source.endUTF16 <= fragment.utf16.count else {
                    throw AIError.invalidResponse("AI odgovor sadrži raspon izvan obrađenog dijela transkripta.")
                }
                proposal.source.startUTF16 += range.location
                proposal.source.endUTF16 += range.location
                try proposal.source.validate(in: transcript)
                guard !proposal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      proposal.projectID.map({ allowedProjects.contains($0) }) ?? true,
                      proposal.relatedEntryID.map({ allowedRelations.contains($0) }) ?? true else {
                    throw AIError.invalidResponse("AI odgovor sadrži nepoznat projekt, izvor ili prazan naziv.")
                }
                proposals.append(proposal)
            }
            offset = NSMaxRange(range)
            progress?(Double(offset) / Double(nsText.length))
        }
        guard offset > 0 else { throw AIError.invalidResponse("Transkript je prazan.") }
        return AnalysisResponse(summary: summaries.joined(separator: "\n\n"), proposals: proposals)
    }

    func ask(question: String, context: [AIContextRecord]) async throws -> AskResponse {
        guard !context.isEmpty else {
            return AskResponse(answer: "U spremljenim podacima nema dovoljno relevantnih izvora za pouzdan odgovor.", sourceIDs: [], insufficientData: true)
        }
        struct Payload: Encodable { let question: String; let context: [AIContextRecord] }
        let result: AskResponse = try await sendJSON(path: "ask", payload: Payload(question: question, context: context))
        let allowed = Set(context.map(\.id))
        guard Set(result.sourceIDs).isSubset(of: allowed),
              result.insufficientData || !result.sourceIDs.isEmpty else {
            throw AIError.invalidResponse("Odgovor nema valjane izvore iz odabranih podataka.")
        }
        return result
    }

    private func sendJSON<P: Encodable, R: Decodable>(path: String, payload: P) async throws -> R {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(payload)
        guard body.count <= 512 * 1_024 else { throw AIError.tooLarge }
        return try await send(path: path, body: body, contentType: "application/json")
    }

    private func send<R: Decodable>(path: String, body: Data, contentType: String) async throws -> R {
        guard let base = AIConfiguration.baseURL else { throw AIError.notConfigured }
        var request = URLRequest(url: base.appendingPathComponent("v1").appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(try AIConfiguration.accessToken(for: base))", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse("Nema odgovora poslužitelja.") }
        guard (200..<300).contains(http.statusCode) else { throw AIError.requestFailed(http.statusCode) }
        guard data.count <= 4 * 1_024 * 1_024 else { throw AIError.tooLarge }
        do { return try JSONDecoder().decode(R.self, from: data) }
        catch { throw AIError.invalidResponse("Odgovor poslužitelja nije u očekivanom strukturiranom formatu. Podaci su sačuvani.") }
    }
}
