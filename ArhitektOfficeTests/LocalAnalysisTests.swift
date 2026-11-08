import XCTest
@testable import ArhitektOffice

@MainActor final class LocalAnalysisTests: XCTestCase {
    func testLongCroatianFixtureCoversEveryUTF16UnitWithoutTruncation() {
        // Synthetic fixture, not a recording or a real business transcript.
        let unit = "Projekt Cerje. Investitor je predložio garažu 🏠, ali odluka nije donesena. Trebam nazvati geodeta.\n"
        let text = String(repeating: unit, count: 300)
        let slices = LocalAnalysisSlice.covering(text)
        let ns = text as NSString
        var next = 0
        var rebuilt = ""
        for slice in slices {
            XCTAssertEqual(slice.startUTF16, next)
            XCTAssertGreaterThan(slice.endUTF16, slice.startUTF16)
            XCTAssertLessThanOrEqual(slice.endUTF16 - slice.startUTF16, 1_802)
            rebuilt += ns.substring(with: NSRange(location: slice.startUTF16, length: slice.endUTF16 - slice.startUTF16))
            next = slice.endUTF16
        }
        XCTAssertGreaterThan(slices.count, 10)
        XCTAssertEqual(next, ns.length)
        XCTAssertEqual(rebuilt, text)
    }

    func testEmptySourceHasNoInventedAnalysisWindows() {
        XCTAssertTrue(LocalAnalysisSlice.covering("").isEmpty)
    }

    func testUniqueEvidenceCannotGuessRepeatedOrOverlappingQuote() {
        XCTAssertNil(LocalAIClient.uniqueRange(of: "geodet", in: "geodet pa ponovno geodet"))
        XCTAssertNil(LocalAIClient.uniqueRange(of: "ana", in: "anana"))
        XCTAssertNil(LocalAIClient.uniqueRange(of: "izmišljeno", in: "Dogovoreno je drugačije."))
        XCTAssertNil(LocalAIClient.uniqueRange(of: "", in: "Izvor"))
    }

    func testEvidencePositionsCountUTF16RatherThanCharacters() throws {
        let text = "😀 Kuća Cerje: nije potvrđena odluka."
        let range = try XCTUnwrap(LocalAIClient.uniqueRange(of: "Kuća Cerje", in: text))
        XCTAssertEqual(range.location, 3)
        XCTAssertEqual((text as NSString).substring(with: range), "Kuća Cerje")
    }

    func testAnalysisCheckpointRetainsEveryCompletedPartAcrossSerialization() throws {
        let slices = LocalAnalysisSlice.covering(String(repeating: "Izvorni događaj. ", count: 500))
        let journal = LocalAnalysisCheckpoint(fingerprint: "local-model-source-context-sha", slices: slices,
            completed: [AnalysisResponse(summary: "Prvi dio ostaje sačuvan", proposals: [])])
        let data = try JSONEncoder().encode(journal)
        let restored = try JSONDecoder().decode(LocalAnalysisCheckpoint.self, from: data)
        XCTAssertEqual(restored.slices, slices)
        XCTAssertEqual(restored.completed.count, 1)
        XCTAssertEqual(restored.completed.first?.summary, "Prvi dio ostaje sačuvan")
    }
}
