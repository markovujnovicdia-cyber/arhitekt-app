import XCTest
import Foundation
@testable import ArhitektOffice

@MainActor
final class LocalModelTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func whisperHeader(vocabulary: UInt32 = 51865, medium: Bool = false) -> Data {
        let values: [UInt32] = medium
            ? [0x67676d6c, vocabulary, 1500, 1024, 16, 24, 448, 1024, 16, 24, 80, 1]
            : [0x67676d6c, vocabulary, 1500, 768, 12, 12, 448, 768, 12, 12, 80, 1]
        return values.reduce(into: Data()) { data, value in data.appendLE(value) }
    }

    private func ggufHeader(quantization: UInt32 = 15, embedding: UInt32 = 2048) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x46554747)); data.appendLE(UInt32(3))
        data.appendLE(UInt64(310)); data.appendLE(UInt64(8))
        data.appendString("general.architecture"); data.appendLE(UInt32(8)); data.appendString("qwen3")
        let integers: [(String, UInt32)] = [
            ("general.file_type", quantization), ("qwen3.block_count", 28),
            ("qwen3.embedding_length", embedding), ("qwen3.feed_forward_length", 6144),
            ("qwen3.attention.head_count", 16), ("qwen3.attention.head_count_kv", 8),
        ]
        for (key, value) in integers { data.appendString(key); data.appendLE(UInt32(4)); data.appendLE(value) }
        data.appendString("tokenizer.ggml.tokens"); data.appendLE(UInt32(9)); data.appendLE(UInt32(8)); data.appendLE(UInt64(151936))
        // Empty tokenizer entries are sufficient for metadata-only tests; native
        // engine loading is intentionally outside this binary-header test.
        data.append(Data(count: 151936 * 8))
        return data
    }

    func testWhisperHeaderDistinguishesMultilingualSmallFromEnglishAndMedium() throws {
        let url = try directory().appendingPathComponent("model.bin")
        try whisperHeader().write(to: url)
        XCTAssertEqual(try LocalModelInspector.inspect(url: url, kind: .whisperSmall, enforceSizeBounds: false).architecture, "whisper-small-multilingual")
        XCTAssertThrowsError(try LocalModelInspector.inspect(url: url, kind: .whisperMedium, enforceSizeBounds: false))
        try whisperHeader(vocabulary: 51864).write(to: url)
        XCTAssertThrowsError(try LocalModelInspector.inspect(url: url, kind: .whisperSmall, enforceSizeBounds: false))
        try whisperHeader(medium: true).write(to: url)
        XCTAssertEqual(try LocalModelInspector.inspect(url: url, kind: .whisperMedium, enforceSizeBounds: false).architecture, "whisper-medium-multilingual")
    }

    func testTruncatedHeaderAndFakeNamedFileAreRejected() throws {
        let url = try directory().appendingPathComponent("Qwen3-1.7B-Q4_K_M.gguf")
        try Data("This is not a model".utf8).write(to: url)
        XCTAssertThrowsError(try LocalModelInspector.inspect(url: url, kind: .qwen3, enforceSizeBounds: false))
        try whisperHeader().prefix(16).write(to: url)
        XCTAssertThrowsError(try LocalModelInspector.inspect(url: url, kind: .whisperSmall, enforceSizeBounds: false))
    }

    func testQwenRequiresExactArchitectureAndQuantizationMetadata() throws {
        let url = try directory().appendingPathComponent("model.gguf")
        try ggufHeader().write(to: url)
        let metadata = try LocalModelInspector.inspect(url: url, kind: .qwen3, enforceSizeBounds: false)
        XCTAssertEqual(metadata.architecture, "qwen3-1.7b")
        XCTAssertEqual(metadata.quantization, "Q4_K_M")
        try ggufHeader(quantization: 14).write(to: url)
        XCTAssertThrowsError(try LocalModelInspector.inspect(url: url, kind: .qwen3, enforceSizeBounds: false))
        try ggufHeader(embedding: 1024).write(to: url)
        XCTAssertThrowsError(try LocalModelInspector.inspect(url: url, kind: .qwen3, enforceSizeBounds: false))
    }

    func testUnboundedOrTruncatedGGUFArrayCannotEscapeFileBounds() throws {
        let url = try directory().appendingPathComponent("bad.gguf")
        var data = Data()
        data.appendLE(UInt32(0x46554747)); data.appendLE(UInt32(3)); data.appendLE(UInt64(310)); data.appendLE(UInt64(1))
        data.appendString("tokenizer.ggml.tokens"); data.appendLE(UInt32(9)); data.appendLE(UInt32(8)); data.appendLE(UInt64.max)
        try data.write(to: url)
        XCTAssertThrowsError(try LocalModelInspector.inspect(url: url, kind: .qwen3, enforceSizeBounds: false))
        try ggufHeader().dropLast(4).write(to: url)
        XCTAssertThrowsError(try LocalModelInspector.inspect(url: url, kind: .qwen3, enforceSizeBounds: false))
    }

    func testMissingModelNeverFallsBackToAnotherEngineOrCloud() throws {
        let store = LocalModelStore(directory: try directory())
        XCTAssertThrowsError(try store.modelURL(for: .whisperSmall))
        XCTAssertThrowsError(try store.modelURL(for: .qwen3))
        XCTAssertTrue(store.manifests.isEmpty)
    }

    func testBadExpectedChecksumCannotReplacePreviouslyImportedModel() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("source.bin")
        try whisperHeader().write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 100 * 1_024 * 1_024)
        try handle.close()
        let store = LocalModelStore(directory: root.appendingPathComponent("installed", isDirectory: true))
        try await store.importModel(from: source, kind: .whisperSmall)
        let previous = try XCTUnwrap(store.manifest(for: .whisperSmall))
        let installed = try store.modelURL(for: .whisperSmall)
        do {
            try await store.importModel(from: source, kind: .whisperSmall, expectedSHA256: String(repeating: "0", count: 64))
            XCTFail("Checksum mismatch must fail")
        } catch LocalModelError.checksumMismatch { }
        XCTAssertEqual(store.manifest(for: .whisperSmall)?.sha256, previous.sha256)
        XCTAssertEqual(store.manifest(for: .whisperSmall)?.fileName, previous.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(try store.modelURL(for: .whisperSmall), installed)
        XCTAssertFalse(store.isImporting)
    }

    func testQuickLookupRejectsSymbolicLinksEvenWhenTheirSizeMatchesManifest() throws {
        let root = try directory()
        let installed = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("external.bin")
        try whisperHeader().write(to: outside)
        let handle = try FileHandle(forWritingTo: outside)
        try handle.truncate(atOffset: 100 * 1_024 * 1_024)
        try handle.close()
        try FileManager.default.createSymbolicLink(at: installed.appendingPathComponent("linked.bin"), withDestinationURL: outside)
        let manifest = LocalModelManifest(kind: .whisperSmall, fileName: "linked.bin", byteCount: 100 * 1_024 * 1_024,
            sha256: String(repeating: "a", count: 64), importedAt: Date(), format: "GGML",
            architecture: "whisper-small-multilingual", quantization: "F16", checksumVerifiedAgainstExpected: false)
        try JSONEncoder().encode([manifest]).write(to: installed.appendingPathComponent("manifest.json"))
        let store = LocalModelStore(directory: installed)
        XCTAssertNotNil(store.manifest(for: .whisperSmall))
        XCTAssertThrowsError(try store.modelURL(for: .whisperSmall))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testThermalAndPhysicalMemoryPolicyFailsBeforeModelLoading() {
        XCTAssertNoThrow(try LocalResourcePolicy.validate(kind: .whisperSmall, physicalMemory: 4 * 1_024 * 1_024 * 1_024, thermalState: .nominal))
        XCTAssertThrowsError(try LocalResourcePolicy.validate(kind: .whisperMedium, physicalMemory: 4 * 1_024 * 1_024 * 1_024, thermalState: .nominal))
        XCTAssertThrowsError(try LocalResourcePolicy.validate(kind: .qwen3, physicalMemory: 8 * 1_024 * 1_024 * 1_024, thermalState: .serious))
        XCTAssertThrowsError(try LocalResourcePolicy.validate(kind: .whisperSmall, physicalMemory: 8 * 1_024 * 1_024 * 1_024, thermalState: .critical))
    }

    func testRuntimeReportUsesActualTokenCountAndGenerationDuration() throws {
        let url = try directory().appendingPathComponent("metrics.json")
        let monitor = LocalRuntimeMonitor(reportURL: url)
        monitor.begin(name: "Qwen3 1.7B Q4_K_M")
        let report = try XCTUnwrap(monitor.finish(outputCharacters: 120, outputTokens: 20, generationSeconds: 2))
        XCTAssertEqual(report.tokensPerSecond, 10)
        XCTAssertEqual(report.outputTokens, 20)
        XCTAssertEqual(report.outputCharacters, 120)
        XCTAssertGreaterThanOrEqual(report.durationSeconds, 0)
        XCTAssertNil(monitor.activeName)
        let reopened = LocalRuntimeMonitor(reportURL: url)
        XCTAssertEqual(reopened.reports.first?.id, report.id)
        XCTAssertEqual(reopened.reports.first?.outputCharacters, 120)
    }

    func testWhisperReportDoesNotInventTokenRateAndOverlappingMeasurementIsMarkedInterrupted() throws {
        let monitor = LocalRuntimeMonitor(reportURL: try directory().appendingPathComponent("metrics.json"))
        monitor.begin(name: "Whisper small")
        monitor.begin(name: "Whisper medium")
        XCTAssertEqual(monitor.reports.count, 1)
        XCTAssertTrue(monitor.reports[0].wasInterrupted)
        let report = try XCTUnwrap(monitor.finish(outputCharacters: 100))
        XCTAssertNil(report.outputTokens)
        XCTAssertNil(report.tokensPerSecond)
        XCTAssertEqual(monitor.reports.count, 2)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    mutating func appendString(_ value: String) {
        let encoded = Data(value.utf8)
        appendLE(UInt64(encoded.count)); append(encoded)
    }
}
