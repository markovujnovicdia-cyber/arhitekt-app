import Foundation
import Combine
import Darwin
import UIKit

struct LocalInferenceMetrics: Codable, Identifiable {
    var id: UUID
    var startedAt: Date
    var modelName: String
    var durationSeconds: Double
    var peakMemoryBytes: UInt64
    var outputCharacters: Int
    var outputTokens: Int?
    var generationSeconds: Double?
    var thermalBefore: String
    var thermalAfter: String
    var wasInterrupted: Bool
    var charactersPerSecond: Double { durationSeconds > 0 ? Double(outputCharacters) / durationSeconds : 0 }
    var tokensPerSecond: Double? {
        guard let outputTokens, outputTokens > 0 else { return nil }
        let seconds = generationSeconds ?? durationSeconds
        return seconds > 0 ? Double(outputTokens) / seconds : nil
    }
    var thermalState: String { thermalAfter }
}

/// Measurements contain counts and resource usage only, never input/output text.
/// phys_footprint is sampled every100ms; the observed peak is a lower bound on
/// the true instantaneous peak, not a guarantee against iOS jetsam termination.
@MainActor
final class LocalRuntimeMonitor: ObservableObject {
    static let shared = LocalRuntimeMonitor()
    @Published private(set) var reports: [LocalInferenceMetrics] = []
    @Published private(set) var activeName: String?
    @Published private(set) var memoryWarningCount = 0
    @Published private(set) var thermalState = LocalRuntimeMonitor.thermalLabel()
    private var timer: Timer?
    private var beganAt: Date?
    private var beganUptime: TimeInterval = 0
    private var peak: UInt64 = 0
    private var initialThermal = ""
    private var interrupted = false
    private var observers: [NSObjectProtocol] = []
    private let reportURL: URL

    init(reportURL: URL? = nil) {
        self.reportURL = reportURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalPerformance", isDirectory: true).appendingPathComponent("reports.json")
        if let data = try? Data(contentsOf: self.reportURL),
           let saved = try? JSONDecoder().decode([LocalInferenceMetrics].self, from: data) {
            reports = Array(saved.prefix(50))
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.memoryWarningCount += 1
                if self.activeName != nil { self.interrupted = true }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.thermalState = Self.thermalLabel()
                if self.activeName != nil, [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) { self.interrupted = true }
            }
        })
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func begin(name: String) {
        // The coordinator admits one engine at a time. Preserve an interrupted
        // report defensively if a caller replaces an unfinished measurement.
        if activeName != nil { _ = finish(outputCharacters: 0, wasInterrupted: true) }
        activeName = name
        beganAt = Date()
        beganUptime = ProcessInfo.processInfo.systemUptime
        initialThermal = Self.thermalLabel()
        thermalState = initialThermal
        interrupted = false
        peak = Self.memoryBytes()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
    }

    @discardableResult
    func finish(outputCharacters: Int, outputTokens: Int? = nil, generationSeconds: Double? = nil, wasInterrupted: Bool = false) -> LocalInferenceMetrics? {
        guard let name = activeName, let beganAt else { return nil }
        sample()
        timer?.invalidate(); timer = nil
        let duration = max(0, ProcessInfo.processInfo.systemUptime - beganUptime)
        let generation = generationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let tokens = outputTokens.flatMap { $0 >= 0 ? $0 : nil }
        let report = LocalInferenceMetrics(id: UUID(), startedAt: beganAt, modelName: name,
            durationSeconds: duration, peakMemoryBytes: peak, outputCharacters: max(0, outputCharacters),
            outputTokens: tokens, generationSeconds: generation, thermalBefore: initialThermal,
            thermalAfter: Self.thermalLabel(), wasInterrupted: wasInterrupted || interrupted)
        activeName = nil; self.beganAt = nil
        reports.insert(report, at: 0)
        if reports.count > 50 { reports.removeLast(reports.count - 50) }
        persist()
        return report
    }

    func clearReports() {
        reports = []
        persist()
    }

    private func sample() {
        peak = max(peak, Self.memoryBytes())
        thermalState = Self.thermalLabel()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try JSONEncoder().encode(reports).write(to: reportURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Measurements remain available in memory. A failed metrics write
            // must not fail an inference or discard user content.
        }
    }

    nonisolated static func memoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    nonisolated static func thermalLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Uobičajeno"
        case .fair: "Povišeno"
        case .serious: "Visoko · obrada se zaustavlja"
        case .critical: "Kritično · obrada se zaustavlja"
        @unknown default: "Nepoznato"
        }
    }
}

enum LocalResourcePolicy {
    /// Advisory process-footprint ceilings. Actual fit depends on model
    /// quantization, context, Metal buffers, device and iOS; none is promised.
    static func maximumFootprintBytes(for kind: LocalModelKind) -> UInt64 {
        switch kind {
        case .whisperSmall: 2 * 1_024 * 1_024 * 1_024
        case .whisperMedium: 3 * 1_024 * 1_024 * 1_024
        case .qwen3: 2_700 * 1_024 * 1_024
        }
    }

    static func validate(kind: LocalModelKind) throws {
        try validate(kind: kind, physicalMemory: ProcessInfo.processInfo.physicalMemory,
                     thermalState: ProcessInfo.processInfo.thermalState)
    }

    // Injectable observations make conservative policy independently testable.
    static func validate(kind: LocalModelKind, physicalMemory: UInt64, thermalState: ProcessInfo.ThermalState) throws {
        guard thermalState != .serious, thermalState != .critical else {
            throw LocalModelError.invalid("iPhone je pregrijan. Lokalna obrada je zaustavljena; pričekajte hlađenje. Snimke i transkripti ostaju sačuvani.")
        }
        let minimum: UInt64 = kind == .whisperSmall ? 3 * 1_024 * 1_024 * 1_024 : 6 * 1_024 * 1_024 * 1_024
        guard physicalMemory >= minimum else {
            throw LocalModelError.invalid(kind == .whisperMedium
                ? "Ovaj uređaj ima premalo fizičke memorije za zadanu politiku Whisper medium modela. Odaberite Whisper small."
                : "Ovaj uređaj ne zadovoljava konzervativni memorijski minimum odabranog lokalnog modela.")
        }
    }
}
