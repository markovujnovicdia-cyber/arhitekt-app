import AVFoundation
import Combine
import Foundation
import Speech

/// Owns a single recording. All state is published on the main actor.
@MainActor
final class SpeechService: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var isPreparing = false
    @Published var errorMessage: String?
    @Published var requiresNetworkConsent = false
    @Published private(set) var usesNetworkRecognition = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var interruptionObserver: NSObjectProtocol?
    private var finalizationTask: Task<Void, Never>?
    private var hasTap = false
    private var sessionID = UUID()

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isRecording || self.isFinishing else { return }
                self.stop()
                self.errorMessage = "Snimanje je prekinuto, primjerice dolaznim pozivom. Prepoznati tekst je sačuvan; provjerite ga ili nastavite novim snimanjem."
            }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        finalizationTask?.cancel()
    }

    func start(allowNetworkRecognition: Bool = false) async {
        guard !isRecording, !isFinishing, !isPreparing else { return }
        isPreparing = true
        errorMessage = nil
        requiresNetworkConsent = false
        defer { isPreparing = false }

        let speechAuthorization: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        guard speechAuthorization == .authorized else {
            errorMessage = speechAuthorization == .restricted
                ? "Prepoznavanje govora je ograničeno na ovom iPhoneu. Tekst možete unijeti ručno."
                : "Dopustite prepoznavanje govora u Postavkama > Privatnost i sigurnost > Prepoznavanje govora. Tekst možete unijeti i ručno."
            return
        }
        let microphoneAllowed: Bool = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        guard microphoneAllowed else {
            errorMessage = "Pristup mikrofonu nije dopušten. Uključite ga u Postavkama > Privatnost i sigurnost > Mikrofon ili unesite tekst ručno."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "hr-HR")) else {
            errorMessage = "Hrvatsko prepoznavanje govora nije dostupno na ovom uređaju. Koristite ručni unos."
            return
        }
        let mode = SpeechRecognitionPolicy.mode(
            supportsOnDevice: recognizer.supportsOnDeviceRecognition,
            networkConsent: allowNetworkRecognition
        )
        guard mode != .requiresConsent else {
            requiresNetworkConsent = true
            return
        }
        guard recognizer.isAvailable else {
            errorMessage = "Prepoznavanje govora trenutačno nije dostupno. Provjerite hrvatski jezik u postavkama iPhonea ili unesite tekst ručno."
            return
        }

        cancel()
        let currentSession = UUID()
        sessionID = currentSession
        transcript = ""
        self.recognizer = recognizer
        let onDevice = mode == .onDevice
        usesNetworkRecognition = !onDevice
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true)
            let speechRequest = SFSpeechAudioBufferRecognitionRequest()
            speechRequest.shouldReportPartialResults = true
            speechRequest.requiresOnDeviceRecognition = onDevice
            speechRequest.taskHint = .dictation
            request = speechRequest
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw RecordingError.noMicrophone
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                speechRequest.append(buffer)
            }
            hasTap = true
            recognitionTask = recognizer.recognitionTask(with: speechRequest) { [weak self] result, error in
                // Copy values before entering the main actor; framework callbacks may use a worker queue.
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let recognitionError = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == currentSession else { return }
                    if let text { self.transcript = text }
                    if isFinal || recognitionError != nil {
                        let wasFinishing = self.isFinishing
                        self.complete()
                        if let recognitionError, !wasFinishing {
                            self.errorMessage = "Prepoznavanje je završilo pogreškom: \(recognitionError). Prepoznati tekst je sačuvan i možete ga urediti."
                        }
                    }
                }
            }
            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            cancel()
            errorMessage = "Snimanje nije moguće pokrenuti: \(error.localizedDescription)"
        }
    }

    /// End input and briefly wait for the recognizer's final correction.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        isFinishing = true
        stopAudio()
        request?.endAudio()
        finalizationTask?.cancel()
        finalizationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.complete()
            self?.errorMessage = "Završna potvrda prijepisa nije stigla na vrijeme. Prepoznati tekst je sačuvan; provjerite ga prije spremanja."
        }
    }

    /// Cancel underlying work while retaining the current transcript.
    func cancel() {
        sessionID = UUID()
        complete()
    }

    private func complete() {
        sessionID = UUID()
        finalizationTask?.cancel()
        finalizationTask = nil
        stopAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
        request = nil
        isRecording = false
        isFinishing = false
    }

    private func stopAudio() {
        engine.stop()
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private enum RecordingError: LocalizedError {
        case noMicrophone
        var errorDescription: String? { "Mikrofon nije dostupan." }
    }
}

/// The only path that permits uploading audio requires explicit per-recording consent.
enum SpeechRecognitionPolicy {
    enum Mode: Equatable { case onDevice, network, requiresConsent }

    static func mode(supportsOnDevice: Bool, networkConsent: Bool) -> Mode {
        if supportsOnDevice { return .onDevice }
        return networkConsent ? .network : .requiresConsent
    }
}
