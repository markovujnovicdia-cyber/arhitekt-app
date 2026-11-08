import Foundation
import Combine
import CryptoKit

enum LocalModelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case whisperSmall, whisperMedium, qwen3
    var id: String { rawValue }
    var title: String {
        switch self {
        case .whisperSmall: "Whisper small · višejezični"
        case .whisperMedium: "Whisper medium · višejezični"
        case .qwen3: "Qwen3 1.7B · Q4_K_M"
        }
    }
    var label: String { title }
    var detail: String {
        switch self {
        case .whisperSmall: "Preporučeni lokalni model za hrvatsku transkripciju; varijante .en nisu podržane."
        case .whisperMedium: "Neobvezni veći model. Zahtijeva više memorije i sporiji je; kvaliteta i brzina ovise o uređaju."
        case .qwen3: "Lokalna analiza i razgovor; GGUF Qwen3-1.7B, isključivo kvantizacija Q4_K_M."
        }
    }
    var suggestedFilename: String {
        switch self {
        case .whisperSmall: "ggml-small.bin"
        case .whisperMedium: "ggml-medium.bin"
        case .qwen3: "Qwen3-1.7B-Q4_K_M.gguf"
        }
    }
    var fileName: String { suggestedFilename }
    fileprivate var byteRange: ClosedRange<Int64> {
        switch self {
        case .whisperSmall: (100 * 1_024 * 1_024)...(800 * 1_024 * 1_024)
        case .whisperMedium: (300 * 1_024 * 1_024)...(2_100 * 1_024 * 1_024)
        case .qwen3: (700 * 1_024 * 1_024)...(1_800 * 1_024 * 1_024)
        }
    }
}

struct LocalModelManifest: Codable, Identifiable, Sendable {
    var kind: LocalModelKind
    var fileName: String
    var byteCount: Int64
    var sha256: String
    var importedAt: Date
    var format: String
    var architecture: String
    var quantization: String
    var checksumVerifiedAgainstExpected: Bool
    var id: String { kind.rawValue }
}

struct LocalModelMetadata: Sendable {
    var format: String
    var architecture: String
    var quantization: String
}

enum LocalModelError: LocalizedError {
    case invalid(String), checksumMismatch, notInstalled(LocalModelKind), engineBusy
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .checksumMismatch: "SHA-256 se ne podudara s očekivanim sažetkom. Novi model nije prihvaćen; prethodni ostaje sačuvan."
        case .notInstalled(let kind): "Model \(kind.title) nije uvezen. Uvezite lokalnu datoteku u postavkama modela. Nema automatskog slanja u oblak."
        case .engineBusy: "Pričekajte završetak lokalne obrade prije uvoza ili brisanja modela."
        }
    }
}

/// Validates the actual binary header and typed GGUF metadata, never a filename.
/// Weight tensors are subsequently validated by the native engine when loading.
enum LocalModelInspector {
    static func inspect(url: URL, kind: LocalModelKind, enforceSizeBounds: Bool = true) throws -> LocalModelMetadata {
        let reader = try ModelBinaryReader(url: url)
        defer { reader.close() }
        if enforceSizeBounds && !kind.byteRange.contains(Int64(reader.fileSize)) {
            throw LocalModelError.invalid("Veličina datoteke ne odgovara odabranom modelu. Provjerite da nije arhiva, poveznica ili nepotpuni prijenos.")
        }
        switch kind {
        case .whisperSmall, .whisperMedium: return try inspectWhisper(reader, kind: kind)
        case .qwen3: return try inspectQwen(reader)
        }
    }

    private static func inspectWhisper(_ reader: ModelBinaryReader, kind: LocalModelKind) throws -> LocalModelMetadata {
        guard try reader.uint32() == 0x67676d6c else {
            throw LocalModelError.invalid("Nije valjana whisper.cpp GGML datoteka.")
        }
        var values: [UInt32] = []
        for _ in 0..<11 { values.append(try reader.uint32()) }
        // whisper.cpp reads exactly these 11 little-endian int32 hparameters.
        // n_vocab=51864 identifies English-only models and must never be accepted for hr.
        let expected: [UInt32] = kind == .whisperSmall
            ? [51865, 1500, 768, 12, 12, 448, 768, 12, 12, 80]
            : [51865, 1500, 1024, 16, 24, 448, 1024, 16, 24, 80]
        guard Array(values.prefix(10)) == expected else {
            throw LocalModelError.invalid("Zaglavlje ne odgovara višejezičnom Whisper \(kind == .whisperSmall ? "small" : "medium") modelu. Engleski .en i drugi modeli nisu prihvaćeni.")
        }
        let type = values[10] % 1000 // GGML_QNT_VERSION_FACTOR from pinned whisper.cpp.
        let quantizations: [UInt32: String] = [0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 7: "Q8_0", 8: "Q5_0", 9: "Q5_1"]
        guard let quantization = quantizations[type] else {
            throw LocalModelError.invalid("Whisper kvantizacija nije podržana ovom verzijom aplikacije.")
        }
        return LocalModelMetadata(format: "GGML", architecture: kind == .whisperSmall ? "whisper-small-multilingual" : "whisper-medium-multilingual", quantization: quantization)
    }

    private static func inspectQwen(_ reader: ModelBinaryReader) throws -> LocalModelMetadata {
        guard try reader.uint32() == 0x46554747 else { throw LocalModelError.invalid("Datoteka nije GGUF model.") }
        let version = try reader.uint32()
        guard [2, 3].contains(version) else { throw LocalModelError.invalid("Nepodržana verzija GGUF datoteke.") }
        let tensors = try reader.uint64()
        let count = try reader.uint64()
        guard tensors > 0, tensors <= 10_000, count > 0, count <= 100_000 else {
            throw LocalModelError.invalid("Nevaljano GGUF zaglavlje ili prevelik broj zapisa.")
        }
        var integers: [String: UInt64] = [:]
        var strings: [String: String] = [:]
        var seen = Set<String>()
        let numericKeys: Set<String> = ["general.file_type", "qwen3.block_count", "qwen3.embedding_length", "qwen3.feed_forward_length", "qwen3.attention.head_count", "qwen3.attention.head_count_kv"]
        for _ in 0..<count {
            try Task.checkCancellation()
            guard reader.offset <= 128 * 1_024 * 1_024 else { throw LocalModelError.invalid("GGUF metapodaci su preveliki.") }
            let key = try reader.string(maximumBytes: 1024)
            guard seen.insert(key).inserted else { throw LocalModelError.invalid("GGUF sadrži ponovljene ključeve.") }
            let type = try reader.uint32()
            if type == 8 {
                if key == "general.architecture" { strings[key] = try reader.string(maximumBytes: 1024) }
                else { try reader.skipString() }
            } else if type == 9 {
                let arrayType = try reader.uint32()
                let arrayCount = try reader.uint64()
                guard arrayCount <= 10_000_000, arrayType != 9 else { throw LocalModelError.invalid("Nevaljano GGUF polje.") }
                if key == "tokenizer.ggml.tokens" {
                    guard arrayType == 8 else { throw LocalModelError.invalid("GGUF rječnik mora biti polje tekstualnih tokena.") }
                    integers["vocabulary_count"] = arrayCount
                }
                try reader.skipArray(type: arrayType, count: arrayCount)
            } else if numericKeys.contains(key) {
                guard [0, 2, 4, 10].contains(type) else { throw LocalModelError.invalid("Nevaljana vrsta ključnog GGUF metapodatka.") }
                integers[key] = try reader.unsignedValue(type: type)
            } else { try reader.skipScalar(type: type) }
        }
        // The exact dense Qwen3-1.7B architecture, not a name containing "Qwen".
        guard strings["general.architecture"] == "qwen3",
              integers["qwen3.block_count"] == 28,
              integers["qwen3.embedding_length"] == 2048,
              integers["qwen3.feed_forward_length"] == 6144,
              integers["qwen3.attention.head_count"] == 16,
              integers["qwen3.attention.head_count_kv"] == 8,
              integers["vocabulary_count"] == 151936,
              integers["general.file_type"] == 15 else {
            throw LocalModelError.invalid("Potreban je točno Qwen3-1.7B GGUF Q4_K_M (28 slojeva, 2048 dimenzija). Drugi modeli ili kvantizacije nisu prihvaćeni.")
        }
        return LocalModelMetadata(format: "GGUF v\(version)", architecture: "qwen3-1.7b", quantization: "Q4_K_M")
    }
}

private final class ModelBinaryReader {
    private let handle: FileHandle
    let fileSize: UInt64
    private(set) var offset: UInt64 = 0
    private var buffer = Data()
    private var bufferStart: UInt64 = 0
    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
    }
    func close() { try? handle.close() }
    private func read(_ length: Int) throws -> Data {
        guard length >= 0, offset <= fileSize, UInt64(length) <= fileSize - offset else {
            throw LocalModelError.invalid("Model je nepotpun ili oštećen.")
        }
        if offset < bufferStart || offset + UInt64(length) > bufferStart + UInt64(buffer.count) {
            try handle.seek(toOffset: offset)
            buffer = try handle.read(upToCount: max(65536, length)) ?? Data()
            bufferStart = offset
        }
        let start = Int(offset - bufferStart)
        guard start + length <= buffer.count else { throw LocalModelError.invalid("Model je nepotpun.") }
        let result = buffer.subdata(in: start..<(start + length))
        offset += UInt64(length)
        return result
    }
    func uint32() throws -> UInt32 {
        let bytes = try read(4)
        return bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }
    func uint64() throws -> UInt64 {
        let bytes = try read(8)
        return bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }
    func string(maximumBytes: UInt64) throws -> String {
        let length = try uint64()
        guard length <= maximumBytes else { throw LocalModelError.invalid("Predugačak GGUF tekstualni zapis.") }
        guard let value = String(data: try read(Int(length)), encoding: .utf8) else { throw LocalModelError.invalid("GGUF tekst nije valjan UTF-8.") }
        return value
    }
    func skipString() throws { try skip(try uint64()) }
    private func skip(_ length: UInt64) throws {
        guard offset <= fileSize, length <= fileSize - offset else { throw LocalModelError.invalid("GGUF model je nepotpun.") }
        offset += length
    }
    func unsignedValue(type: UInt32) throws -> UInt64 {
        switch type {
        case 0: return UInt64(try read(1).first!)
        case 2: return try read(2).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        case 4: return UInt64(try uint32())
        case 10: return try uint64()
        default: throw LocalModelError.invalid("Nepodržan tip GGUF broja.")
        }
    }
    func skipScalar(type: UInt32) throws {
        switch type {
        case 0, 1, 7: try skip(1)
        case 2, 3: try skip(2)
        case 4, 5, 6: try skip(4)
        case 10, 11, 12: try skip(8)
        case 8: try skipString()
        default: throw LocalModelError.invalid("Nepodržan GGUF tip podatka.")
        }
    }
    func skipArray(type: UInt32, count: UInt64) throws {
        if type == 8 {
            for _ in 0..<count {
                try Task.checkCancellation()
                try skipString()
            }
        } else {
            let width: UInt64
            switch type {
            case 0, 1, 7: width = 1
            case 2, 3: width = 2
            case 4, 5, 6: width = 4
            case 10, 11, 12: width = 8
            default: throw LocalModelError.invalid("Nepodržan GGUF tip polja.")
            }
            guard count <= UInt64.max / width else { throw LocalModelError.invalid("Preveliko GGUF polje.") }
            try skip(count * width)
        }
    }
}

@MainActor
final class LocalModelStore: ObservableObject {
    static let shared = LocalModelStore()
    @Published private(set) var manifests: [LocalModelManifest] = []
    @Published private(set) var isImporting = false
    @Published private(set) var progress: Double = 0
    @Published var errorMessage: String?
    @Published var selectedWhisperKind: LocalModelKind = .whisperSmall {
        didSet {
            if selectedWhisperKind == .qwen3 { selectedWhisperKind = oldValue; return }
            UserDefaults.standard.set(selectedWhisperKind.rawValue, forKey: "office.local.whisperKind")
        }
    }
    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("manifest.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models", isDirectory: true)
        if let stored = UserDefaults.standard.string(forKey: "office.local.whisperKind"),
           let kind = LocalModelKind(rawValue: stored), kind != .qwen3 { selectedWhisperKind = kind }
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var url = self.directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                manifests = try JSONDecoder().decode([LocalModelManifest].self, from: Data(contentsOf: indexURL))
                guard Set(manifests.map(\.kind)).count == manifests.count,
                      manifests.allSatisfy({ value in
                          !value.fileName.isEmpty && value.fileName == (value.fileName as NSString).lastPathComponent &&
                          !value.fileName.contains("..") && !value.fileName.contains("/") && !value.fileName.contains("\\") &&
                          value.sha256.count == 64 && value.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }) &&
                          value.kind.byteRange.contains(value.byteCount)
                      }) else { throw LocalModelError.invalid("Popis modela sadrži nevaljane zapise ili duplikate.") }
            }
        } catch { errorMessage = "Popis lokalnih modela nije moguće otvoriti: \(error.localizedDescription)"; manifests = [] }
    }

    func manifest(for kind: LocalModelKind) -> LocalModelManifest? { manifests.first { $0.kind == kind } }

    /// Fast main-actor lookup only. Import verifies SHA-256/header/typed metadata
    /// on its worker; the native loader validates tensors off the main actor.
    /// This method deliberately does not rescan the large GGUF tokenizer or
    /// recompute a multi-gigabyte digest on every generation.
    func modelURL(for kind: LocalModelKind) throws -> URL {
        guard let manifest = manifest(for: kind), !manifest.fileName.isEmpty,
              manifest.fileName == (manifest.fileName as NSString).lastPathComponent,
              !manifest.fileName.contains(".."), !manifest.fileName.contains("/"),
              !manifest.fileName.contains("\\") else { throw LocalModelError.notInstalled(kind) }
        let url = directory.appendingPathComponent(manifest.fileName).standardizedFileURL
        guard url.deletingLastPathComponent() == directory.standardizedFileURL else {
            throw LocalModelError.invalid("Putanja modela nije unutar mape lokalnih modela.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, Int64(size) == manifest.byteCount,
              kind.byteRange.contains(manifest.byteCount), manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw LocalModelError.invalid("Datoteka modela nedostaje ili je promijenjena. Ponovno je uvezite.")
        }
        return url
    }

    func importModel(from source: URL, kind: LocalModelKind, expectedSHA256: String? = nil) async throws {
        guard !isImporting, !LocalInferenceCoordinator.shared.isBusy else { throw LocalModelError.engineBusy }
        let expected = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let expected, !expected.isEmpty {
            guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
                throw LocalModelError.invalid("Očekivani SHA-256 mora imati točno 64 heksadekadska znaka.")
            }
        }
        isImporting = true; progress = 0; errorMessage = nil
        defer { isImporting = false }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let temporary = directory.appendingPathComponent(".import-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let worker = Task.detached(priority: .utility) { [weak self] in
            try LocalModelImportWorker.copy(source: source, destination: temporary, kind: kind, expected: expected) { value in
                Task { @MainActor [weak self] in self?.progress = value }
            }
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            let fileName = "\(kind.rawValue)-\(UUID().uuidString).\(kind == .qwen3 ? "gguf" : "bin")"
            let destination = directory.appendingPathComponent(fileName)
            try FileManager.default.moveItem(at: temporary, to: destination)
            let previous = manifest(for: kind)
            let manifest = LocalModelManifest(kind: kind, fileName: fileName, byteCount: result.bytes,
                sha256: result.hash, importedAt: Date(), format: result.metadata.format,
                architecture: result.metadata.architecture, quantization: result.metadata.quantization,
                checksumVerifiedAgainstExpected: !(expected ?? "").isEmpty)
            let updated = manifests.filter { $0.kind != kind } + [manifest]
            do { try saveIndex(updated) }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
            manifests = updated
            progress = 1
            if let previous { try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous.fileName)) }
        } catch { errorMessage = error.localizedDescription; throw error }
    }

    func remove(_ kind: LocalModelKind) throws {
        guard !isImporting, !LocalInferenceCoordinator.shared.isBusy else { throw LocalModelError.engineBusy }
        guard let previous = manifest(for: kind) else { return }
        let updated = manifests.filter { $0.kind != kind }
        try saveIndex(updated)
        manifests = updated
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous.fileName))
    }

    private func saveIndex(_ values: [LocalModelManifest]) throws {
        let data = try JSONEncoder().encode(values)
        try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

private enum LocalModelImportWorker {
    static func copy(source: URL, destination: URL, kind: LocalModelKind, expected: String?, progress: (Double) -> Void) throws -> (bytes: Int64, hash: String, metadata: LocalModelMetadata) {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, kind.byteRange.contains(Int64(size)) else {
            throw LocalModelError.invalid("Odaberite cjelovitu lokalnu datoteku očekivanog modela; veličina nije valjana.")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        var copied: Int64 = 0
        while let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: data)
            hasher.update(data: data)
            copied += Int64(data.count)
            guard copied <= Int64(size) else { throw LocalModelError.invalid("Izvorna datoteka promijenjena je tijekom uvoza.") }
            progress(Double(copied) / Double(size) * 0.95)
        }
        try output.synchronize()
        guard copied == Int64(size) else { throw LocalModelError.invalid("Prijenos modela nije potpun.") }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected, !expected.isEmpty, expected != hash { throw LocalModelError.checksumMismatch }
        let metadata = try LocalModelInspector.inspect(url: destination, kind: kind)
        return (copied, hash, metadata)
    }
}
