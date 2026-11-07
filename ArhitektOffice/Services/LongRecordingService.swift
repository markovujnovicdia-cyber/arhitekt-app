import AVFoundation
import Combine
import Foundation
import SwiftData

/// Continuous, local-first recording. A PCM CAF master avoids encoding-container
/// finalization dependencies and chunk-boundary gaps. Only upload copies are AAC.
@MainActor
final class LongRecordingService: NSObject, ObservableObject {
    static let shared = LongRecordingService()
    enum State: Equatable { case idle, preparing, recording, paused, finished }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentSession: RecordingSession?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var playingSessionID: UUID?
    @Published var errorMessage: String?
    @Published private(set) var recoveryWarnings: [String] = []

    private let store: RecordingFileStore
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var context: ModelContext?
    private var manifest: RecordingFileStore.Manifest?
    private var timer: Timer?
    private var lastCheckpoint: Date = .distantPast
    private var exportingSessions: Set<UUID> = []
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?

    init(store: RecordingFileStore = .shared) {
        self.store = store
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .recording {
                    self.pause(interrupted: true)
                    self.errorMessage = "Snimanje je pauzirano zbog prekida, primjerice poziva. Prethodni zvuk je sačuvan. Kad budete spremni, dodirnite Nastavi."
                }
                self.stopPlayback()
            }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                self.pause(interrupted: true)
                self.errorMessage = "Mikrofon ili slušalice su odspojeni. Snimanje je pauzirano; provjerite mikrofon i nastavite ručno."
            }
        }
    }

    deinit {
        timer?.invalidate()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    func start(project: Project?, context: ModelContext, title: String = "Snimka") async {
        guard state != .recording, state != .paused, state != .preparing else { return }
        stopPlayback()
        state = .preparing
        errorMessage = nil
        let permitted: Bool = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { state = .idle; return }
        guard permitted else {
            state = .idle
            errorMessage = "Dopustite pristup mikrofonu u Postavkama > Privatnost i sigurnost > Mikrofon."
            return
        }
        currentSession = nil
        self.context = nil
        manifest = nil
        recorder = nil
        do {
            if context.hasChanges { try context.save() }
            let session = RecordingSession(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Snimka" : title, project: project)
            // The journal exists even if the app exits before the model save.
            var journal = try store.createManifest(id: session.id, title: session.title, projectID: project?.id, createdAt: session.createdAt)
            session.masterRelativePath = journal.masterRelativePath
            session.stateRaw = "preparing"
            self.currentSession = session
            self.context = context
            self.manifest = journal
            context.insert(session)
            try context.save()
            elapsed = 0
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
            // PCM is deliberate: written frames stay useful without an MP4 index.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let recorder = try AVAudioRecorder(url: store.url(for: journal.masterRelativePath), settings: settings)
            self.recorder = recorder
            recorder.delegate = self
            guard recorder.prepareToRecord() else { throw RecordingError.startFailed }
            try store.protect(journal.masterRelativePath)
            journal.state = "recording"
            journal.updatedAt = Date()
            try store.write(journal)
            self.manifest = journal
            session.stateRaw = "recording"
            session.updatedAt = Date()
            try context.save()
            guard recorder.record() else { throw RecordingError.startFailed }
            state = .recording
            lastCheckpoint = Date()
            startTimer()
        } catch {
            recorder?.stop()
            recorder = nil
            state = currentSession == nil ? .idle : .finished
            currentSession?.stateRaw = "error"
            currentSession?.lastError = error.localizedDescription
            currentSession?.updatedAt = Date()
            try? self.context?.save()
            if var journal = manifest {
                journal.state = "error"
                journal.updatedAt = Date()
                try? store.write(journal)
                manifest = journal
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = "Snimanje nije pokrenuto: \(error.localizedDescription). Postojeće datoteke nisu izbrisane."
        }
    }

    func pause() { pause(interrupted: false) }

    private func pause(interrupted: Bool) {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
        timer?.invalidate()
        timer = nil
        do { try checkpoint(state: interrupted ? "interrupted" : "paused") }
        catch { errorMessage = "Zvuk je pauziran, ali dnevnik nije spremljen: \(error.localizedDescription). Datoteka ostaje na uređaju." }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func resume() throws {
        guard state == .paused, let recorder else { throw RecordingError.noActiveSession }
        stopPlayback()
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try AVAudioSession.sharedInstance().setActive(true)
        guard recorder.record() else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw RecordingError.startFailed
        }
        state = .recording
        do { try checkpoint(state: "recording") }
        catch {
            recorder.pause()
            state = .paused
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        errorMessage = nil
        startTimer()
    }

    /// Stop only finalizes local storage; no network request is made here.
    func finish() throws {
        guard state == .recording || state == .paused else { return }
        elapsed = max(elapsed, recorder?.currentTime ?? 0)
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        state = .finished
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try checkpoint(state: "stopped")
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                self.elapsed = max(self.elapsed, self.recorder?.currentTime ?? 0)
                if Date().timeIntervalSince(self.lastCheckpoint) >= 5 {
                    do { try self.checkpoint(state: "recording") }
                    catch {
                        self.recorder?.pause()
                        self.state = .paused
                        self.timer?.invalidate()
                        self.timer = nil
                        self.errorMessage = "Snimanje je pauzirano jer spremanje dnevnika nije uspjelo: \(error.localizedDescription). Zvuk nije izbrisan."
                    }
                }
            }
        }
    }

    private func checkpoint(state: String) throws {
        guard var journal = manifest, let session = currentSession else { throw RecordingError.noActiveSession }
        elapsed = max(elapsed, recorder?.currentTime ?? 0)
        journal.duration = elapsed
        journal.updatedAt = Date()
        journal.state = state
        // Journal first; a later launch can restore metadata after a DB failure.
        try store.write(journal)
        manifest = journal
        session.duration = elapsed
        session.stateRaw = state
        session.updatedAt = journal.updatedAt
        session.project?.touch()
        try context?.save()
        lastCheckpoint = Date()
    }

    /// Reconcile journals with SwiftData without deleting or re-recording audio.
    @discardableResult
    func recoverSessions(context: ModelContext) throws -> [RecordingSession] {
        let scan = try store.scanRecoveryManifests()
        recoveryWarnings = scan.warnings
        let existing = try context.fetch(FetchDescriptor<RecordingSession>())
        let projects = try context.fetch(FetchDescriptor<Project>())
        var recovered: [RecordingSession] = []
        for journal in scan.manifests {
            if currentSession?.id == journal.id, state == .recording || state == .paused { continue }
            let session: RecordingSession
            if let stored = existing.first(where: { $0.id == journal.id }) { session = stored }
            else {
                session = RecordingSession(title: journal.title, project: projects.first(where: { $0.id == journal.projectID }))
                session.id = journal.id
                session.createdAt = journal.createdAt
                context.insert(session)
            }
            session.masterRelativePath = journal.masterRelativePath
            session.duration = max(session.duration, journal.duration)
            session.updatedAt = max(session.updatedAt, journal.updatedAt)
            if ["recording", "preparing", "paused", "interrupted"].contains(journal.state) {
                session.stateRaw = "recovered"
                session.lastError = "Snimanje je prekinuto. Dostupni zvuk je sačuvan; provjerite snimku prije obrade."
            } else if session.stateRaw != "audioDeleted" {
                session.stateRaw = journal.state
            }
            for entry in journal.segments where !session.segments.contains(where: { $0.index == entry.index }) {
                context.insert(AudioSegment(index: entry.index, relativePath: entry.relativePath, duration: entry.duration, session: session))
            }
            recovered.append(session)
        }
        try context.save()
        return recovered
    }

    /// Safe to retry. Existing segment IDs/transcripts are preserved by index.
    func prepareSegments(for session: RecordingSession, context: ModelContext) async throws -> [AudioSegment] {
        guard !exportingSessions.contains(session.id) else { throw RecordingError.processingInProgress }
        exportingSessions.insert(session.id)
        defer { exportingSessions.remove(session.id) }
        guard !(currentSession?.id == session.id && (state == .recording || state == .paused)),
              let masterPath = session.masterRelativePath else { throw RecordingError.recordingInProgress }
        let entries = try await store.exportSegments(id: session.id, masterRelativePath: masterPath)
        var journal = try store.readManifest(id: session.id)
        journal.segments = entries
        journal.updatedAt = Date()
        journal.duration = entries.reduce(0) { $0 + $1.duration }
        try store.write(journal)
        for entry in entries {
            if let existing = session.segments.first(where: { $0.index == entry.index }) {
                existing.relativePath = entry.relativePath
                existing.duration = entry.duration
            } else {
                context.insert(AudioSegment(index: entry.index, relativePath: entry.relativePath, duration: entry.duration, session: session))
            }
        }
        session.duration = journal.duration
        session.updatedAt = Date()
        try context.save()
        return session.segments.sorted { $0.index < $1.index }
    }

    func play(_ session: RecordingSession) throws {
        guard state != .recording, state != .paused, state != .preparing else { throw RecordingError.recordingInProgress }
        guard let path = session.masterRelativePath else { throw RecordingError.noAudio }
        stopPlayback()
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        let player = try AVAudioPlayer(contentsOf: store.url(for: path))
        player.delegate = self
        guard player.prepareToPlay(), player.play() else { throw RecordingError.noAudio }
        self.player = player
        playingSessionID = session.id
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingSessionID = nil
        if state != .recording && state != .paused && state != .preparing {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func deleteAudio(for session: RecordingSession, context: ModelContext) throws {
        guard !exportingSessions.contains(session.id) else { throw RecordingError.processingInProgress }
        guard !(currentSession?.id == session.id && (state == .recording || state == .paused || state == .preparing)) else {
            throw RecordingError.recordingInProgress
        }
        if playingSessionID == session.id { stopPlayback() }
        try store.deleteAudio(id: session.id)
        // Preserve transcript history and metadata, including segment transcripts.
        session.masterRelativePath = nil
        session.stateRaw = "audioDeleted"
        session.updatedAt = Date()
        for segment in session.segments { segment.stateRaw = "audioDeleted" }
        try context.save()
    }

    enum RecordingError: LocalizedError {
        case startFailed, noActiveSession, recordingInProgress, processingInProgress, noAudio
        var errorDescription: String? {
            switch self {
            case .startFailed: "Mikrofon nije moguće pokrenuti. Provjerite dostupnost mikrofona i slobodan prostor."
            case .noActiveSession: "Nema aktivne snimke za nastavak."
            case .recordingInProgress: "Najprije završite aktivno snimanje."
            case .processingInProgress: "Priprema zvučnog zapisa je u tijeku. Pričekajte završetak."
            case .noAudio: "Audio datoteka nije dostupna. Transkripti ostaju sačuvani."
            }
        }
    }
}

extension LongRecordingService: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let active = self.recorder, ObjectIdentifier(active) == identity,
                  self.state == .recording || self.state == .paused else { return }
            do { try self.finish() } catch { self.errorMessage = error.localizedDescription }
            if !flag {
                self.currentSession?.lastError = "Snimanje je neočekivano prekinuto. Provjerite sačuvani zvuk."
                self.errorMessage = self.currentSession?.lastError
                try? self.context?.save()
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let description = error?.localizedDescription ?? "Nepoznata pogreška snimanja."
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let active = self.recorder, ObjectIdentifier(active) == identity else { return }
            do { try self.finish() } catch { }
            self.currentSession?.lastError = description
            self.errorMessage = "Snimanje je prekinuto: \(description). Prethodno spremljeni zvuk nije izbrisan."
            try? self.context?.save()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let active = self.player, ObjectIdentifier(active) == identity else { return }
            self.stopPlayback()
        }
    }
}
