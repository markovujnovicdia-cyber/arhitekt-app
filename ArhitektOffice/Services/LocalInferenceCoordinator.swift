import Foundation
import Combine
import UIKit
#if canImport(AOWhisper)
import AOWhisper
#endif
#if canImport(AOLlama)
import AOLlama
#endif

struct LocalTranscriptSegment: Decodable, Sendable {
    let start: Double
    let end: Double
    let text: String
}
struct LocalTranscriptResult: Decodable, Sendable {
    let text: String
    let segments: [LocalTranscriptSegment]
}
struct LocalGenerationResult: Decodable, Sendable {
    let text: String
    let generatedTokens: Int
    let promptTokens: Int
    let generationSeconds: Double?
    let stopReason: String
}

enum LocalInferenceError: LocalizedError {
    case busy, engineUnavailable, interrupted(String), invalidOutput, contextTooLarge, failure(String)
    var errorDescription: String? {
        switch self {
        case .busy: "Drugi lokalni model već obrađuje podatke ili se uvozi model. Pričekajte pa nastavite."
        case .engineUnavailable: "Izvorne AI biblioteke nisu povezane s aplikacijom. Na Macu prvo pokrenite tools/build-local-engines.sh i ponovno izgradite Xcode projekt. Nema mrežne zamjene."
        case .interrupted(let reason): "Lokalna obrada je pauzirana: \(reason). Dosad obrađeni dijelovi ostaju spremljeni; pokušajte nastaviti kasnije."
        case .invalidOutput: "Lokalni model nije vratio valjan, provjerljiv rezultat. Izvorni podaci nisu promijenjeni."
        case .contextTooLarge: "Odabrani kontekst ne stane u lokalni model. Odaberite manje izvora ili kraće pitanje."
        case .failure(let detail): "Lokalni model nije dovršio obradu: \(detail). Izvorni podaci ostaju sačuvani."
        }
    }
}

/// C callbacks consult only this lock-protected cancellation object. There is no
/// network client and no engine can run alongside another large engine.
private final class NativeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?
    private let footprintLimit: UInt64
    init(footprintLimit: UInt64) { self.footprintLimit = footprintLimit }
    func cancel(_ reason: String) { lock.lock(); defer { lock.unlock() }; self.reason = self.reason ?? reason }
    var interruptionReason: String? { lock.lock(); defer { lock.unlock() }; return reason }
    func shouldAbort() -> Int32 {
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            cancel("uređaj se zagrijao; pričekajte da se ohladi")
        }
        // This is a stop threshold, not an assertion that iOS grants this memory.
        if LocalRuntimeMonitor.memoryBytes() > footprintLimit { cancel("dosegnut je zaštitni prag memorije") }
        return interruptionReason == nil ? 0 : 1
    }
}

private let nativeCancelCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { pointer in
    guard let pointer else { return 1 }
    return Unmanaged<NativeCancellation>.fromOpaque(pointer).takeUnretainedValue().shouldAbort()
}

@MainActor final class LocalInferenceCoordinator: ObservableObject {
    static let shared = LocalInferenceCoordinator()
    @Published private(set) var isBusy = false
    @Published private(set) var activeKind: LocalModelKind?
    private let worker = DispatchQueue(label: "office.local-inference", qos: .userInitiated)

    var selectedWhisperFingerprint: String {
        get throws {
            let store = LocalModelStore.shared
            _ = try store.modelURL(for: store.selectedWhisperKind)
            guard let manifest = store.manifest(for: store.selectedWhisperKind) else { throw LocalInferenceError.invalidOutput }
            return manifest.sha256
        }
    }

    func transcribe(samples: [Float], prompt: String, progress: ((Double) -> Void)? = nil) async throws -> LocalTranscriptResult {
        let kind = LocalModelStore.shared.selectedWhisperKind
        guard kind == .whisperSmall || kind == .whisperMedium else { throw LocalInferenceError.invalidOutput }
        guard !samples.isEmpty, samples.count <= 16_000 * 35,
              samples.allSatisfy(\.isFinite) else { throw LocalInferenceError.invalidOutput }
        let url = try prepare(kind: kind)
        let flag = NativeCancellation(footprintLimit: LocalResourcePolicy.maximumFootprintBytes(for: kind))
        let observers = observeInterruptions(flag)
        LocalRuntimeMonitor.shared.begin(name: kind.rawValue)
        progress?(0)
        do {
            let result: LocalTranscriptResult = try await execute(flag: flag) {
                #if canImport(AOWhisper)
                var output: UnsafeMutablePointer<CChar>?
                let errorCapacity = 2_048
                var error = [CChar](repeating: 0, count: errorCapacity)
                let pointer = Unmanaged.passUnretained(flag).toOpaque()
                let status = samples.withUnsafeBufferPointer { audio in
                    url.path.withCString { model in
                        "hr".withCString { language in
                            prompt.withCString { prefix in
                                ao_whisper_transcribe(model, audio.baseAddress, Int32(audio.count), language, prefix,
                                    Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))), 1,
                                    nativeCancelCallback, pointer, &output, &error, errorCapacity)
                            }
                        }
                    }
                }
                defer { if let output { ao_whisper_free_text(output) } }
                return try Self.decode(status: status, output: output, error: error, flag: flag)
                #else
                throw LocalInferenceError.engineUnavailable
                #endif
            }
            progress?(1)
            LocalRuntimeMonitor.shared.finish(outputCharacters: result.text.count)
            cleanup(observers)
            return result
        } catch {
            LocalRuntimeMonitor.shared.finish(outputCharacters: 0, wasInterrupted: true)
            cleanup(observers)
            throw error
        }
    }

    func generate(prompt: String, maximumTokens: Int = 1_536) async throws -> LocalGenerationResult {
        guard prompt.utf8.count <= 48_000 else { throw LocalInferenceError.contextTooLarge }
        let url = try prepare(kind: .qwen3)
        let flag = NativeCancellation(footprintLimit: LocalResourcePolicy.maximumFootprintBytes(for: .qwen3))
        let observers = observeInterruptions(flag)
        LocalRuntimeMonitor.shared.begin(name: LocalModelKind.qwen3.rawValue)
        do {
            let result: LocalGenerationResult = try await execute(flag: flag) {
                #if canImport(AOLlama)
                var output: UnsafeMutablePointer<CChar>?
                let errorCapacity = 2_048
                var error = [CChar](repeating: 0, count: errorCapacity)
                let status = url.path.withCString { model in
                    prompt.withCString { text in
                        ao_llama_generate(model, text, 8_192, Int32(max(128, min(maximumTokens, 2_048))),
                            Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))), 99,
                            nativeCancelCallback, Unmanaged.passUnretained(flag).toOpaque(), &output, &error, errorCapacity)
                    }
                }
                defer { if let output { ao_llama_free_text(output) } }
                return try Self.decode(status: status, output: output, error: error, flag: flag)
                #else
                throw LocalInferenceError.engineUnavailable
                #endif
            }
            LocalRuntimeMonitor.shared.finish(outputCharacters: result.text.count, outputTokens: result.generatedTokens,
                                              generationSeconds: result.generationSeconds, wasInterrupted: result.stopReason != "eos")
            cleanup(observers)
            guard result.stopReason == "eos" else {
                throw LocalInferenceError.failure("dosegnuta je granica generiranja; djelomičan odgovor nije prihvaćen")
            }
            return result
        } catch {
            LocalRuntimeMonitor.shared.finish(outputCharacters: 0, wasInterrupted: true)
            cleanup(observers)
            throw error
        }
    }

    private func prepare(kind: LocalModelKind) throws -> URL {
        guard !isBusy, !LocalModelStore.shared.isImporting else { throw LocalInferenceError.busy }
        try LocalResourcePolicy.validate(kind: kind)
        let url = try LocalModelStore.shared.modelURL(for: kind)
        isBusy = true; activeKind = kind
        return url
    }
    private func observeInterruptions(_ flag: NativeCancellation) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        return [center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            flag.cancel("iOS je prijavio nedostatak memorije")
        }, center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            flag.cancel("aplikacija je otišla u pozadinu")
        }]
    }
    private func cleanup(_ observers: [NSObjectProtocol]) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        // Native calls have already destroyed their context and model here.
        activeKind = nil; isBusy = false
    }
    private func execute<T: Sendable>(flag: NativeCancellation, work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                worker.async {
                    do {
                        try Task.checkCancellation()
                        if let reason = flag.interruptionReason { throw LocalInferenceError.interrupted(reason) }
                        continuation.resume(returning: try work())
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { flag.cancel("korisnik je prekinuo obradu") }
    }
    private nonisolated static func decode<T: Decodable>(status: Int32, output: UnsafeMutablePointer<CChar>?,
                                                        error: [CChar], flag: NativeCancellation) throws -> T {
        if status == 2 || flag.interruptionReason != nil {
            throw LocalInferenceError.interrupted(flag.interruptionReason ?? "obrada je prekinuta")
        }
        guard status == 0, let output else { throw LocalInferenceError.failure(String(cString: error)) }
        let text = String(cString: output)
        guard let data = text.data(using: .utf8), data.count <= 4 * 1_024 * 1_024 else { throw LocalInferenceError.invalidOutput }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
